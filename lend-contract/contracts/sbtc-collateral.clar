;; sBTC Collateral Manager Contract
;; Manages Bitcoin collateral deposits/withdrawals via sBTC bridge
;; Includes collateral validation, reserve management, and emergency controls

;; SIP-010 Trait for sBTC token
(define-trait sip-010-trait
  (
    (transfer (uint principal principal (optional (buff 34))) (response bool uint))
    (get-name () (response (string-ascii 32) uint))
    (get-symbol () (response (string-ascii 32) uint))
    (get-decimals () (response uint uint))
    (get-balance (principal) (response uint uint))
    (get-total-supply () (response uint uint))
    (get-token-uri (uint) (response (optional (string-utf8 256)) uint))
  )
)

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u100))
(define-constant ERR_INSUFFICIENT_COLLATERAL (err u101))
(define-constant ERR_INVALID_AMOUNT (err u102))
(define-constant ERR_CONTRACT_PAUSED (err u103))
(define-constant ERR_WITHDRAWAL_NOT_FOUND (err u104))
(define-constant ERR_COLLATERAL_RATIO_TOO_LOW (err u105))
(define-constant ERR_RESERVE_INSUFFICIENT (err u106))
(define-constant ERR_INVALID_BITCOIN_ADDRESS (err u107))
(define-constant ERR_DEPOSIT_NOT_FOUND (err u108))

;; Minimum collateral ratio (150% = 15000 basis points)
(define-constant MIN_COLLATERAL_RATIO u15000)
;; Liquidation threshold (120% = 12000 basis points)
(define-constant LIQUIDATION_THRESHOLD u12000)
;; Reserve ratio (10% = 1000 basis points)
(define-constant RESERVE_RATIO u1000)

;; Data Variables
(define-data-var contract-paused bool false)
(define-data-var emergency-admin (optional principal) none)
(define-data-var total-collateral uint u0)
(define-data-var total-reserves uint u0)
(define-data-var sbtc-token-contract (optional principal) none)

;; Data Maps
(define-map user-collateral principal uint)
(define-map user-debt principal uint)
(define-map deposit-requests 
  uint 
  {
    user: principal,
    amount: uint,
    bitcoin-address: (string-ascii 64),
    status: (string-ascii 20),
    created-at: uint
  }
)
(define-map withdrawal-requests 
  uint 
  {
    user: principal,
    amount: uint,
    bitcoin-address: (string-ascii 64),
    status: (string-ascii 20),
    created-at: uint
  }
)
(define-map authorized-operators principal bool)

;; Counters
(define-data-var next-deposit-id uint u1)
(define-data-var next-withdrawal-id uint u1)

;; Emergency Controls
(define-public (pause-contract)
  (begin
    (asserts! (or (is-eq tx-sender CONTRACT_OWNER) 
                  (is-some (get-emergency-admin))) ERR_UNAUTHORIZED)
    (var-set contract-paused true)
    (ok true)
  )
)

(define-public (unpause-contract)
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (var-set contract-paused false)
    (ok true)
  )
)

(define-public (set-emergency-admin (admin principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (var-set emergency-admin (some admin))
    (ok true)
  )
)

;; Operator Management
(define-public (add-operator (operator principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (map-set authorized-operators operator true)
    (ok true)
  )
)

(define-public (remove-operator (operator principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (map-delete authorized-operators operator)
    (ok true)
  )
)

;; sBTC Token Contract Management
(define-public (set-sbtc-token-contract (token-contract principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (var-set sbtc-token-contract (some token-contract))
    (ok true)
  )
)

;; Collateral Management
(define-public (deposit-collateral (amount uint) (bitcoin-address (string-ascii 64)))
  (let (
    (deposit-id (var-get next-deposit-id))
    (current-collateral (default-to u0 (map-get? user-collateral tx-sender)))
  )
    (asserts! (not (var-get contract-paused)) ERR_CONTRACT_PAUSED)
    (asserts! (> amount u0) ERR_INVALID_AMOUNT)
    (asserts! (> (len bitcoin-address) u0) ERR_INVALID_BITCOIN_ADDRESS)
    
    ;; Create deposit request
    (map-set deposit-requests deposit-id {
      user: tx-sender,
      amount: amount,
      bitcoin-address: bitcoin-address,
      status: "pending",
      created-at: block-height
    })
    
    (var-set next-deposit-id (+ deposit-id u1))
    (ok deposit-id)
  )
)

(define-public (confirm-deposit (deposit-id uint))
  (let (
    (deposit-data (unwrap! (map-get? deposit-requests deposit-id) ERR_DEPOSIT_NOT_FOUND))
    (user (get user deposit-data))
    (amount (get amount deposit-data))
    (current-collateral (default-to u0 (map-get? user-collateral user)))
  )
    (asserts! (default-to false (map-get? authorized-operators tx-sender)) ERR_UNAUTHORIZED)
    (asserts! (is-eq (get status deposit-data) "pending") ERR_DEPOSIT_NOT_FOUND)
    
    ;; Update user collateral
    (map-set user-collateral user (+ current-collateral amount))
    
    ;; Update total collateral
    (var-set total-collateral (+ (var-get total-collateral) amount))
    
    ;; Update deposit status
    (map-set deposit-requests deposit-id 
      (merge deposit-data { status: "confirmed" }))
    
    (ok true)
  )
)

(define-public (initiate-withdrawal (amount uint) (bitcoin-address (string-ascii 64)))
  (let (
    (withdrawal-id (var-get next-withdrawal-id))
    (current-collateral (default-to u0 (map-get? user-collateral tx-sender)))
    (current-debt (default-to u0 (map-get? user-debt tx-sender)))
    (remaining-collateral (- current-collateral amount))
  )
    (asserts! (not (var-get contract-paused)) ERR_CONTRACT_PAUSED)
    (asserts! (> amount u0) ERR_INVALID_AMOUNT)
    (asserts! (>= current-collateral amount) ERR_INSUFFICIENT_COLLATERAL)
    (asserts! (> (len bitcoin-address) u0) ERR_INVALID_BITCOIN_ADDRESS)
    
    ;; Check collateral ratio after withdrawal
    (asserts! (or (is-eq current-debt u0)
                  (>= (calculate-collateral-ratio remaining-collateral current-debt) MIN_COLLATERAL_RATIO))
              ERR_COLLATERAL_RATIO_TOO_LOW)
    
    ;; Create withdrawal request
    (map-set withdrawal-requests withdrawal-id {
      user: tx-sender,
      amount: amount,
      bitcoin-address: bitcoin-address,
      status: "pending",
      created-at: block-height
    })
    
    (var-set next-withdrawal-id (+ withdrawal-id u1))
    (ok withdrawal-id)
  )
)

(define-public (process-withdrawal (withdrawal-id uint))
  (let (
    (withdrawal-data (unwrap! (map-get? withdrawal-requests withdrawal-id) ERR_WITHDRAWAL_NOT_FOUND))
    (user (get user withdrawal-data))
    (amount (get amount withdrawal-data))
    (current-collateral (default-to u0 (map-get? user-collateral user)))
  )
    (asserts! (default-to false (map-get? authorized-operators tx-sender)) ERR_UNAUTHORIZED)
    (asserts! (is-eq (get status withdrawal-data) "pending") ERR_WITHDRAWAL_NOT_FOUND)
    
    ;; Update user collateral
    (map-set user-collateral user (- current-collateral amount))
    
    ;; Update total collateral
    (var-set total-collateral (- (var-get total-collateral) amount))
    
    ;; Update withdrawal status
    (map-set withdrawal-requests withdrawal-id 
      (merge withdrawal-data { status: "processed" }))
    
    (ok true)
  )
)

;; Debt Management
(define-public (mint-sbtc (amount uint))
  (let (
    (current-collateral (default-to u0 (map-get? user-collateral tx-sender)))
    (current-debt (default-to u0 (map-get? user-debt tx-sender)))
    (new-debt (+ current-debt amount))
    (reserve-amount (/ (* amount RESERVE_RATIO) u10000))
  )
    (asserts! (not (var-get contract-paused)) ERR_CONTRACT_PAUSED)
    (asserts! (> amount u0) ERR_INVALID_AMOUNT)
    (asserts! (>= (calculate-collateral-ratio current-collateral new-debt) MIN_COLLATERAL_RATIO)
              ERR_COLLATERAL_RATIO_TOO_LOW)
    
    ;; Update user debt
    (map-set user-debt tx-sender new-debt)
    
    ;; Add to reserves
    (var-set total-reserves (+ (var-get total-reserves) reserve-amount))
    
    ;; Mint sBTC tokens (would interact with sBTC contract)
    ;; This is a placeholder - actual implementation would call sBTC mint function
    
    (ok amount)
  )
)

(define-public (burn-sbtc (amount uint))
  (let (
    (current-debt (default-to u0 (map-get? user-debt tx-sender)))
    (new-debt (- current-debt amount))
  )
    (asserts! (not (var-get contract-paused)) ERR_CONTRACT_PAUSED)
    (asserts! (> amount u0) ERR_INVALID_AMOUNT)
    (asserts! (>= current-debt amount) ERR_INSUFFICIENT_COLLATERAL)
    
    ;; Update user debt
    (map-set user-debt tx-sender new-debt)
    
    ;; Burn sBTC tokens (would interact with sBTC contract)
    ;; This is a placeholder - actual implementation would call sBTC burn function
    
    (ok true)
  )
)

;; Liquidation
(define-public (liquidate-position (user principal))
  (let (
    (user-collateral-amount (default-to u0 (map-get? user-collateral user)))
    (user-debt-amount (default-to u0 (map-get? user-debt user)))
    (collateral-ratio (calculate-collateral-ratio user-collateral-amount user-debt-amount))
  )
    (asserts! (not (var-get contract-paused)) ERR_CONTRACT_PAUSED)
    (asserts! (< collateral-ratio LIQUIDATION_THRESHOLD) ERR_COLLATERAL_RATIO_TOO_LOW)
    
    ;; Clear user positions
    (map-delete user-collateral user)
    (map-delete user-debt user)
    
    ;; Update totals
    (var-set total-collateral (- (var-get total-collateral) user-collateral-amount))
    
    (ok true)
  )
)

;; Utility Functions
(define-read-only (calculate-collateral-ratio (collateral uint) (debt uint))
  (if (is-eq debt u0)
    u0
    (/ (* collateral u10000) debt)
  )
)

(define-read-only (get-user-collateral (user principal))
  (default-to u0 (map-get? user-collateral user))
)

(define-read-only (get-user-debt (user principal))
  (default-to u0 (map-get? user-debt user))
)

(define-read-only (get-user-collateral-ratio (user principal))
  (let (
    (collateral (get-user-collateral user))
    (debt (get-user-debt user))
  )
    (calculate-collateral-ratio collateral debt)
  )
)

(define-read-only (get-deposit-request (deposit-id uint))
  (map-get? deposit-requests deposit-id)
)

(define-read-only (get-withdrawal-request (withdrawal-id uint))
  (map-get? withdrawal-requests withdrawal-id)
)

(define-read-only (is-contract-paused)
  (var-get contract-paused)
)

(define-read-only (get-emergency-admin)
  (var-get emergency-admin)
)

(define-read-only (get-total-collateral)
  (var-get total-collateral)
)

(define-read-only (get-total-reserves)
  (var-get total-reserves)
)

(define-read-only (is-authorized-operator (operator principal))
  (default-to false (map-get? authorized-operators operator))
)

;; Health check function
(define-read-only (get-system-health)
  {
    total-collateral: (var-get total-collateral),
    total-reserves: (var-get total-reserves),
    contract-paused: (var-get contract-paused),
    min-collateral-ratio: MIN_COLLATERAL_RATIO,
    liquidation-threshold: LIQUIDATION_THRESHOLD
  }
)
