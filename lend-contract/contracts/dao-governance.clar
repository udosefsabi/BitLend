;; DAO Governance Smart Contract
;; A flexible, reusable governance system for any DAO project

;; ============================================================================
;; DATA STRUCTURES & STORAGE
;; ============================================================================

;; Voting tokens balance
(define-map voting-tokens
{ account: principal }
{ amount: uint }
)

;; Proposals storage
(define-map proposals
{ proposal-id: uint }
{
title: (string-ascii 256),
description: (string-ascii 1024),
proposer: principal,
start-block: uint,
end-block: uint,
votes-for: uint,
votes-against: uint,
executed: bool,
proposal-type: (string-ascii 32),
execution-data: (optional (buff 1024))
}
)

;; User votes per proposal
(define-map user-votes
{ proposal-id: uint, voter: principal }
{ vote: bool, amount: uint }
)

;; DAO Configuration
(define-map dao-config
{ key: (string-ascii 32) }
{ value: uint }
)

;; DAO Treasury
(define-data-var treasury-balance uint u0)

;; Proposal counter
(define-data-var proposal-count uint u0)

;; Voting token total supply
(define-data-var total-supply uint u0)

;; DAO owner (can be transferred to governance contract)
(define-data-var dao-owner principal tx-sender)

;; ============================================================================
;; CONSTANTS
;; ============================================================================

(define-constant CONTRACT-OWNER tx-sender)
(define-constant MIN-PROPOSAL-DURATION u10) ;; Minimum blocks for proposal voting
(define-constant MAX-PROPOSAL-DURATION u100000) ;; Maximum blocks for proposal voting
(define-constant VOTING-THRESHOLD u100) ;; Minimum votes needed (in basis points, 100 = 1%)

;; ============================================================================
;; INITIALIZATION FUNCTIONS
;; ============================================================================

;; Initialize DAO with voting tokens for an account
(define-public (initialize-voting-tokens (account principal) (amount uint))
(begin
(asserts! (is-eq tx-sender (var-get dao-owner)) (err u1))
(asserts! (> amount u0) (err u2))
(map-set voting-tokens { account: account } { amount: amount })
(var-set total-supply (+ (var-get total-supply) amount))
(ok amount)
)
)

;; Set DAO configuration parameters
(define-public (set-config (key (string-ascii 32)) (value uint))
(begin
(asserts! (is-eq tx-sender (var-get dao-owner)) (err u1))
(map-set dao-config { key: key } { value: value })
(ok value)
)
)

;; Transfer DAO ownership to governance contract
(define-public (transfer-dao-owner (new-owner principal))
(begin
(asserts! (is-eq tx-sender (var-get dao-owner)) (err u1))
(var-set dao-owner new-owner)
(ok new-owner)
)
)

;; ============================================================================
;; VOTING TOKEN FUNCTIONS
;; ============================================================================

;; Get voting token balance
(define-read-only (get-balance (account principal))
(default-to u0 (get amount (map-get? voting-tokens { account: account })))
)

;; Transfer voting tokens
(define-public (transfer-tokens (to principal) (amount uint))
(let ((from-balance (get-balance tx-sender)))
(begin
(asserts! (>= from-balance amount) (err u3))
(asserts! (> amount u0) (err u2))
(map-set voting-tokens 
{ account: tx-sender } 
{ amount: (- from-balance amount) }
)
(map-set voting-tokens 
{ account: to } 
{ amount: (+ (get-balance to) amount) }
)
(ok amount)
)
)
)

;; ============================================================================
;; PROPOSAL FUNCTIONS
;; ============================================================================

;; Create a new proposal
(define-public (create-proposal 
(title (string-ascii 256))
(description (string-ascii 1024))
(duration uint)
(proposal-type (string-ascii 32))
)
(let (
(proposal-id (var-get proposal-count))
(proposer-balance (get-balance tx-sender))
)
(begin
;; Validate inputs
(asserts! (> proposer-balance u0) (err u4)) ;; Proposer must have voting tokens
(asserts! (>= duration MIN-PROPOSAL-DURATION) (err u5))
(asserts! (<= duration MAX-PROPOSAL-DURATION) (err u6))
;; Store proposal
(map-set proposals
{ proposal-id: proposal-id }
{
title: title,
description: description,
proposer: tx-sender,
start-block: block-height,
end-block: (+ block-height duration),
votes-for: u0,
votes-against: u0,
executed: false,
proposal-type: proposal-type,
execution-data: none
}
)
;; Increment proposal counter
(var-set proposal-count (+ proposal-id u1))
(ok proposal-id)
)
)
)

;; Get proposal details
(define-read-only (get-proposal (proposal-id uint))
(map-get? proposals { proposal-id: proposal-id })
)

;; ============================================================================
;; VOTING FUNCTIONS
;; ============================================================================

;; Vote on a proposal
(define-public (vote (proposal-id uint) (vote-for bool))
(let (
(proposal (unwrap! (get-proposal proposal-id) (err u7)))
(voter-balance (get-balance tx-sender))
(user-vote (map-get? user-votes { proposal-id: proposal-id, voter: tx-sender }))
)
(begin
;; Validate voting conditions
(asserts! (is-none user-vote) (err u8)) ;; User already voted
(asserts! (> voter-balance u0) (err u9)) ;; Must have voting tokens
(asserts! (< block-height (get end-block proposal)) (err u10)) ;; Voting period must be active
(asserts! (>= block-height (get start-block proposal)) (err u11)) ;; Voting hasn't started yet
;; Record vote
(map-set user-votes
{ proposal-id: proposal-id, voter: tx-sender }
{ vote: vote-for, amount: voter-balance }
)
;; Update proposal vote counts
(if vote-for
(map-set proposals
{ proposal-id: proposal-id }
(merge proposal { votes-for: (+ (get votes-for proposal) voter-balance) })
)
(map-set proposals
{ proposal-id: proposal-id }
(merge proposal { votes-against: (+ (get votes-against proposal) voter-balance) })
)
)
(ok true)
)
)
)

;; Get user's vote on a proposal
(define-read-only (get-user-vote (proposal-id uint) (voter principal))
(map-get? user-votes { proposal-id: proposal-id, voter: voter })
)

;; Check if proposal passed (more votes for than against)
(define-read-only (proposal-passed (proposal-id uint))
(let ((proposal (unwrap! (get-proposal proposal-id) (err u7))))
(ok (> (get votes-for proposal) (get votes-against proposal)))
)
)

;; ============================================================================
;; PROPOSAL EXECUTION
;; ============================================================================

;; Execute a passed proposal
(define-public (execute-proposal (proposal-id uint))
(let ((proposal (unwrap! (get-proposal proposal-id) (err u7))))
(begin
;; Validate execution conditions
(asserts! (is-eq tx-sender (var-get dao-owner)) (err u1))
(asserts! (> (get end-block proposal) block-height) (err u12)) ;; Voting must be complete
(asserts! (not (get executed proposal)) (err u13)) ;; Already executed
(asserts! (> (get votes-for proposal) (get votes-against proposal)) (err u14))
;; Mark as executed
(map-set proposals
{ proposal-id: proposal-id }
(merge proposal { executed: true })
)
(ok true)
)
)
)

;; ============================================================================
;; TREASURY FUNCTIONS
;; ============================================================================

;; Deposit to treasury
(define-public (deposit-to-treasury (amount uint))
(begin
(asserts! (> amount u0) (err u2))
(var-set treasury-balance (+ (var-get treasury-balance) amount))
(ok amount)
)
)

;; Withdraw from treasury (only DAO owner)
(define-public (withdraw-from-treasury (amount uint) (recipient principal))
(let ((current-balance (var-get treasury-balance)))
(begin
(asserts! (is-eq tx-sender (var-get dao-owner)) (err u1))
(asserts! (<= amount current-balance) (err u15)) ;; Insufficient treasury balance
(var-set treasury-balance (- current-balance amount))
(ok amount)
)
)
)

;; Get treasury balance
(define-read-only (get-treasury-balance)
(var-get treasury-balance)
)

;; ============================================================================
;; HELPER FUNCTIONS
;; ============================================================================

;; Get total supply of voting tokens
(define-read-only (get-total-supply)
(var-get total-supply)
)

;; Get number of proposals
(define-read-only (get-proposal-count)
(var-get proposal-count)
)

;; Get DAO owner
(define-read-only (get-dao-owner)
(var-get dao-owner)
)

;; Get config value
(define-read-only (get-config (key (string-ascii 32)))
(map-get? dao-config { key: key })
)

;; Calculate voting power percentage
(define-read-only (get-voting-power-percentage (account principal))
(let ((account-balance (get-balance account))
(total (var-get total-supply)))
(if (> total u0)
(ok (/ (* account-balance u10000) total)) ;; Returns basis points (100 = 1%)
(ok u0)
)
)
)

;; ============================================================================
;; ERROR CODES
;; ============================================================================
;; u1 - Unauthorized (not DAO owner)
;; u2 - Invalid amount (must be > 0)
;; u3 - Insufficient balance
;; u4 - Proposer has no voting tokens
;; u5 - Duration below minimum
;; u6 - Duration exceeds maximum
;; u7 - Proposal not found
;; u8 - User already voted
;; u9 - No voting tokens
;; u10 - Voting period has ended
;; u11 - Voting hasn't started
;; u12 - Voting still in progress
;; u13 - Proposal already executed
;; u14 - Proposal did not pass
;; u15 - Insufficient treasury balance
