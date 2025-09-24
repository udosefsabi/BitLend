;; Bitlend Core Protocol - Main Smart Contract
;; Handles BTC collateral, lending positions, health factors, and liquidations

;; =============================================================================
;; CONSTANTS AND ERROR CODES
;; =============================================================================

(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-UNAUTHORIZED (err u100))
(define-constant ERR-INSUFFICIENT-COLLATERAL (err u101))
(define-constant ERR-POSITION-NOT-FOUND (err u102))
(define-constant ERR-UNHEALTHY-POSITION (err u103))
(define-constant ERR-LIQUIDATION-NOT-ALLOWED (err u104))
(define-constant ERR-INVALID-AMOUNT (err u105))
(define-constant ERR-MARKET-PAUSED (err u106))
(define-constant ERR-PRICE-FEED-STALE (err u107))
(define-constant ERR-POSITION-UPDATE-FAILED (err u245))

;; Protocol parameters
(define-constant LIQUIDATION-THRESHOLD u150) ;; 150% collateralization ratio
(define-constant LIQUIDATION-PENALTY u110)   ;; 10% liquidation penalty
(define-constant MIN-COLLATERAL-RATIO u120)  ;; 120% minimum ratio
(define-constant PRECISION u1000000)         ;; 6 decimal precision
(define-constant MAX-LTV u80)                ;; 80% max loan-to-value

;; =============================================================================
;; DATA VARIABLES
;; =============================================================================

(define-data-var protocol-paused bool false)
(define-data-var total-collateral uint u0)
(define-data-var total-borrowed uint u0)
(define-data-var btc-price uint u0)
(define-data-var price-last-updated uint u0)
(define-data-var liquidation-fee uint u50000) ;; 5% in basis points

;; =============================================================================
;; DATA MAPS
;; =============================================================================

;; User positions tracking
(define-map user-positions
  { user: principal }
  {
    collateral-amount: uint,
    borrowed-amount: uint,
    last-interaction: uint,
    health-factor: uint,
    liquidation-price: uint
  }
)

;; Collateral deposits
(define-map collateral-deposits
  { user: principal, deposit-id: uint }
  {
    amount: uint,
    timestamp: uint,
    locked: bool
  }
)

;; Liquidation records
(define-map liquidation-history
  { liquidation-id: uint }
  {
    liquidated-user: principal,
    liquidator: principal,
    collateral-seized: uint,
    debt-repaid: uint,
    timestamp: uint
  }
)

;; Market parameters per asset
(define-map market-config
  { asset: (string-ascii 10) }
  {
    collateral-factor: uint,
    liquidation-threshold: uint,
    reserve-factor: uint,
    interest-rate: uint,
    is-active: bool
  }
)

;; User deposit counters
(define-map user-deposit-counter
  { user: principal }
  { counter: uint }
)

;; Global counters
(define-data-var liquidation-counter uint u0)

;; =============================================================================
;; PRIVATE FUNCTIONS
;; =============================================================================

;; Calculate health factor for a position
(define-private (calculate-health-factor (collateral uint) (debt uint) (btc-price-val uint))
  (if (is-eq debt u0)
    u999999999 ;; Infinite health factor if no debt
    (/ (* collateral btc-price-val PRECISION) (* debt LIQUIDATION-THRESHOLD))
  )
)

;; Calculate liquidation price
(define-private (calculate-liquidation-price (collateral uint) (debt uint))
  (if (is-eq collateral u0)
    u0
    (/ (* debt LIQUIDATION-THRESHOLD) (* collateral PRECISION))
  )
)

;; Validate price feed freshness
(define-private (is-price-fresh)
  (< (- block-height (var-get price-last-updated)) u144) ;; 24 hours in blocks
)

;; Update user position
(define-private (update-user-position (user principal) (collateral uint) (debt uint))
  (let (
    (current-btc-price (var-get btc-price))
    (health-factor (calculate-health-factor collateral debt current-btc-price))
    (liq-price (calculate-liquidation-price collateral debt))
  )
    (map-set user-positions
      { user: user }
      {
        collateral-amount: collateral,
        borrowed-amount: debt,
        last-interaction: block-height,
        health-factor: health-factor,
        liquidation-price: liq-price
      }
    )
    (ok true)
  )
)

;; =============================================================================
;; PUBLIC FUNCTIONS - COLLATERAL MANAGEMENT
;; =============================================================================

;; Deposit BTC collateral
(define-public (deposit-collateral (amount uint))
  (let (
    (user tx-sender)
    (current-position (default-to 
      { collateral-amount: u0, borrowed-amount: u0, last-interaction: u0, health-factor: u999999999, liquidation-price: u0 }
      (map-get? user-positions { user: user })
    ))
    (deposit-counter (default-to { counter: u0 } (map-get? user-deposit-counter { user: user })))
    (new-counter (+ (get counter deposit-counter) u1))
    (new-collateral (+ (get collateral-amount current-position) amount))
  )
    (asserts! (not (var-get protocol-paused)) ERR-MARKET-PAUSED)
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    
    ;; Transfer BTC to contract (assuming wrapped BTC token)
    ;; (try! (contract-call? .wrapped-btc transfer amount tx-sender (as-contract tx-sender) none))
    
    ;; Record deposit
    (map-set collateral-deposits
      { user: user, deposit-id: new-counter }
      {
        amount: amount,
        timestamp: block-height,
        locked: false
      }
    )
    
    ;; Update counters
    (map-set user-deposit-counter { user: user } { counter: new-counter })
    (var-set total-collateral (+ (var-get total-collateral) amount))
    
    ;; Update position
    (unwrap! (update-user-position user new-collateral (get borrowed-amount current-position)) (err u203))
    
    (ok { deposited: amount, total-collateral: new-collateral })
  )
)

;; Withdraw collateral
(define-public (withdraw-collateral (amount uint))
  (let (
    (user tx-sender)
    (current-position (unwrap! (map-get? user-positions { user: user }) ERR-POSITION-NOT-FOUND))
    (current-collateral (get collateral-amount current-position))
    (current-debt (get borrowed-amount current-position))
    (new-collateral (- current-collateral amount))
    (current-btc-price (var-get btc-price))
  )
    (asserts! (not (var-get protocol-paused)) ERR-MARKET-PAUSED)
    (asserts! (is-price-fresh) ERR-PRICE-FEED-STALE)
    (asserts! (>= current-collateral amount) ERR-INSUFFICIENT-COLLATERAL)
    
    ;; Check if withdrawal maintains healthy position
    (let ((new-health-factor (calculate-health-factor new-collateral current-debt current-btc-price)))
      (asserts! (>= new-health-factor PRECISION) ERR-UNHEALTHY-POSITION)
      
      ;; Update position
      (unwrap! (update-user-position user new-collateral current-debt) (err u241))
      (var-set total-collateral (- (var-get total-collateral) amount))
      
      ;; Transfer BTC back to user
      ;; (try! (as-contract (contract-call? .wrapped-btc transfer amount tx-sender user none)))
      
      (ok { withdrawn: amount, remaining-collateral: new-collateral })
    )
  )
)

;; =============================================================================
;; PUBLIC FUNCTIONS - BORROWING
;; =============================================================================

;; Borrow against collateral
(define-public (borrow (amount uint))
  (let (
    (user tx-sender)
    (current-position (unwrap! (map-get? user-positions { user: user }) ERR-POSITION-NOT-FOUND))
    (current-collateral (get collateral-amount current-position))
    (current-debt (get borrowed-amount current-position))
    (new-debt (+ current-debt amount))
    (current-btc-price (var-get btc-price))
  )
    (asserts! (not (var-get protocol-paused)) ERR-MARKET-PAUSED)
    (asserts! (is-price-fresh) ERR-PRICE-FEED-STALE)
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    
    ;; Check collateralization ratio
    (let ((health-factor (calculate-health-factor current-collateral new-debt current-btc-price)))
      (asserts! (>= health-factor PRECISION) ERR-INSUFFICIENT-COLLATERAL)
      
      ;; Update position
      (unwrap! (update-user-position user current-collateral new-debt) (err u242))
      (var-set total-borrowed (+ (var-get total-borrowed) amount))
      
      ;; Mint borrowed tokens to user
      ;; (try! (contract-call? .bitlend-token mint amount user))
      
      (ok { borrowed: amount, total-debt: new-debt, health-factor: health-factor })
    )
  )
)

;; Repay borrowed amount
(define-public (repay (amount uint))
  (let (
    (user tx-sender)
    (current-position (unwrap! (map-get? user-positions { user: user }) ERR-POSITION-NOT-FOUND))
    (current-debt (get borrowed-amount current-position))
    (repay-amount (if (> amount current-debt) current-debt amount))
    (new-debt (- current-debt repay-amount))
  )
    (asserts! (not (var-get protocol-paused)) ERR-MARKET-PAUSED)
    (asserts! (> repay-amount u0) ERR-INVALID-AMOUNT)
    
    ;; Burn repaid tokens
    ;; (try! (contract-call? .bitlend-token burn repay-amount user))
    
    ;; Update position
    (unwrap! (update-user-position user (get collateral-amount current-position) new-debt) (err u243))
    (var-set total-borrowed (- (var-get total-borrowed) repay-amount))
    
    (ok { repaid: repay-amount, remaining-debt: new-debt })
  )
)

;; =============================================================================
;; PUBLIC FUNCTIONS - LIQUIDATION
;; =============================================================================

;; Liquidate unhealthy position
(define-public (liquidate-position (user-to-liquidate principal) (repay-amount uint))
  (let (
    (liquidator tx-sender)
    (position (unwrap! (map-get? user-positions { user: user-to-liquidate }) ERR-POSITION-NOT-FOUND))
    (current-collateral (get collateral-amount position))
    (current-debt (get borrowed-amount position))
    (health-factor (get health-factor position))
    (liquidation-id (+ (var-get liquidation-counter) u1))
  )
    (asserts! (not (var-get protocol-paused)) ERR-MARKET-PAUSED)
    (asserts! (is-price-fresh) ERR-PRICE-FEED-STALE)
    (asserts! (< health-factor PRECISION) ERR-LIQUIDATION-NOT-ALLOWED)
    (asserts! (<= repay-amount current-debt) ERR-INVALID-AMOUNT)
    
    ;; Calculate collateral to seize (with penalty)
    (let (
      (collateral-value (* current-collateral (var-get btc-price)))
      (repay-value (* repay-amount PRECISION))
      (base-collateral-to-seize (/ repay-value (var-get btc-price)))
      (penalty-amount (/ (* base-collateral-to-seize LIQUIDATION-PENALTY) u100))
      (total-collateral-seized (+ base-collateral-to-seize penalty-amount))
      (remaining-collateral (- current-collateral total-collateral-seized))
      (remaining-debt (- current-debt repay-amount))
    )
      ;; Ensure we don't seize more collateral than available
      (asserts! (<= total-collateral-seized current-collateral) ERR-INSUFFICIENT-COLLATERAL)
      
      ;; Burn liquidator's repayment tokens
      ;; (try! (contract-call? .bitlend-token burn repay-amount liquidator))
      
      ;; Transfer seized collateral to liquidator
      ;; (try! (as-contract (contract-call? .wrapped-btc transfer total-collateral-seized tx-sender liquidator none)))
      
      ;; Update liquidated user's position
      (unwrap! (update-user-position user-to-liquidate remaining-collateral remaining-debt) ERR-POSITION-UPDATE-FAILED)
      
      ;; Record liquidation
      (map-set liquidation-history
        { liquidation-id: liquidation-id }
        {
          liquidated-user: user-to-liquidate,
          liquidator: liquidator,
          collateral-seized: total-collateral-seized,
          debt-repaid: repay-amount,
          timestamp: block-height
        }
      )
      
      ;; Update global counters
      (var-set liquidation-counter liquidation-id)
      (var-set total-collateral (- (var-get total-collateral) total-collateral-seized))
      (var-set total-borrowed (- (var-get total-borrowed) repay-amount))
      
      (ok {
        liquidation-id: liquidation-id,
        collateral-seized: total-collateral-seized,
        debt-repaid: repay-amount,
        penalty: penalty-amount
      })
    )
  )
)

;; =============================================================================
;; PUBLIC FUNCTIONS - ORACLE AND ADMIN
;; =============================================================================

;; Update BTC price (oracle function)
(define-public (update-btc-price (new-price uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (var-set btc-price new-price)
    (var-set price-last-updated block-height)
    (ok new-price)
  )
)

;; Pause/unpause protocol
(define-public (set-protocol-paused (paused bool))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (var-set protocol-paused paused)
    (ok paused)
  )
)

;; =============================================================================
;; READ-ONLY FUNCTIONS
;; =============================================================================

;; Get user position
(define-read-only (get-user-position (user principal))
  (map-get? user-positions { user: user })
)

;; Get position health factor
(define-read-only (get-health-factor (user principal))
  (match (map-get? user-positions { user: user })
    position (ok (get health-factor position))
    ERR-POSITION-NOT-FOUND
  )
)

;; Check if position is liquidatable
(define-read-only (is-liquidatable (user principal))
  (match (map-get? user-positions { user: user })
    position (ok (< (get health-factor position) PRECISION))
    ERR-POSITION-NOT-FOUND
  )
)

;; Get protocol stats
(define-read-only (get-protocol-stats)
  (ok {
    total-collateral: (var-get total-collateral),
    total-borrowed: (var-get total-borrowed),
    btc-price: (var-get btc-price),
    price-last-updated: (var-get price-last-updated),
    protocol-paused: (var-get protocol-paused),
    total-liquidations: (var-get liquidation-counter)
  })
)

;; Get liquidation details
(define-read-only (get-liquidation (liquidation-id uint))
  (map-get? liquidation-history { liquidation-id: liquidation-id })
)

;; Calculate max borrowable amount
(define-read-only (get-max-borrowable (user principal))
  (match (map-get? user-positions { user: user })
    position 
    (let (
      (collateral-value (* (get collateral-amount position) (var-get btc-price)))
      (max-borrow-value (/ (* collateral-value MAX-LTV) u100))
      (current-debt-value (* (get borrowed-amount position) PRECISION))
    )
      (ok (if (> max-borrow-value current-debt-value)
            (/ (- max-borrow-value current-debt-value) PRECISION)
            u0))
    )
    (ok u0)
  )
)

;; Get current collateralization ratio
(define-read-only (get-collateralization-ratio (user principal))
  (match (map-get? user-positions { user: user })
    position
    (let (
      (collateral-value (* (get collateral-amount position) (var-get btc-price)))
      (debt-value (* (get borrowed-amount position) PRECISION))
    )
      (ok (if (is-eq debt-value u0)
            u999999999
            (/ (* collateral-value u100) debt-value)))
    )
    ERR-POSITION-NOT-FOUND
  )
)
