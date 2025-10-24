;; Time-Bound Access Control Smart Contract
;; Implements temporal permissions, session management, and scheduled operations

;; ============================================================================
;; CONSTANTS
;; ============================================================================

(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-UNAUTHORIZED (err u100))
(define-constant ERR-INVALID-TIME (err u101))
(define-constant ERR-SESSION-EXPIRED (err u102))
(define-constant ERR-SESSION-LIMIT-EXCEEDED (err u103))
(define-constant ERR-PERMISSION-NOT-FOUND (err u104))
(define-constant ERR-PERMISSION-EXPIRED (err u105))
(define-constant ERR-SCHEDULE-NOT-FOUND (err u106))
(define-constant ERR-INVALID-PARAMETERS (err u107))

;; ============================================================================
;; DATA VARIABLES
;; ============================================================================

;; Added counters for generating unique IDs instead of hashing
(define-data-var session-counter uint u0)
(define-data-var operation-counter uint u0)
(define-data-var pattern-counter uint u0)

;; ============================================================================
;; DATA STRUCTURES
;; ============================================================================

;; Temporal Permission: time-limited access grants
(define-map temporal-permissions
  { user: principal, resource: (string-ascii 64) }
  {
    start-time: uint,
    end-time: uint,
    is-active: bool,
    access-level: uint,
    created-at: uint,
    last-modified: uint
  }
)

;; Session Management: session-based access tokens
(define-map sessions
  { session-id: uint, user: principal }
  {
    created-at: uint,
    last-activity: uint,
    idle-timeout: uint,
    is-active: bool,
    resource: (string-ascii 64)
  }
)

;; Session counter per user for concurrent session limits
(define-map user-session-count
  { user: principal }
  { count: uint, max-sessions: uint }
)

;; Scheduled Operations: pre-authorized future transactions
(define-map scheduled-operations
  { operation-id: uint }
  {
    user: principal,
    operation-type: (string-ascii 32),
    scheduled-time: uint,
    execution-time: (optional uint),
    is-executed: bool,
    is-cancelled: bool,
    data: (buff 1024),
    created-at: uint
  }
)

;; Recurring Permission Patterns
(define-map recurring-permissions
  { user: principal, pattern-id: uint }
  {
    resource: (string-ascii 64),
    interval: uint,
    start-time: uint,
    end-time: (optional uint),
    access-level: uint,
    is-active: bool,
    created-at: uint
  }
)

;; Emergency Time Extensions
(define-map emergency-extensions
  { user: principal, resource: (string-ascii 64) }
  {
    original-end-time: uint,
    extended-end-time: uint,
    extension-reason: (string-ascii 128),
    approved-by: principal,
    created-at: uint
  }
)

;; ============================================================================
;; TEMPORAL PERMISSIONS
;; ============================================================================

;; Grant time-limited access to a resource
(define-public (grant-temporal-permission
  (user principal)
  (resource (string-ascii 64))
  (start-time uint)
  (end-time uint)
  (access-level uint)
)
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (asserts! (< start-time end-time) ERR-INVALID-TIME)
    (asserts! (>= start-time block-height) ERR-INVALID-TIME)
    
    (map-set temporal-permissions
      { user: user, resource: resource }
      {
        start-time: start-time,
        end-time: end-time,
        is-active: true,
        access-level: access-level,
        created-at: block-height,
        last-modified: block-height
      }
    )
    (ok true)
  )
)

;; Revoke temporal permission
(define-public (revoke-temporal-permission
  (user principal)
  (resource (string-ascii 64))
)
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (asserts! (is-some (map-get? temporal-permissions { user: user, resource: resource })) ERR-PERMISSION-NOT-FOUND)
    
    (map-set temporal-permissions
      { user: user, resource: resource }
      (merge
        (unwrap! (map-get? temporal-permissions { user: user, resource: resource }) ERR-PERMISSION-NOT-FOUND)
        { is-active: false, last-modified: block-height }
      )
    )
    (ok true)
  )
)

;; Check if user has valid temporal permission
(define-public (has-valid-permission
  (user principal)
  (resource (string-ascii 64))
)
  (let (
    (permission (map-get? temporal-permissions { user: user, resource: resource }))
  )
    (match permission
      perm (ok (and
        (get is-active perm)
        (>= block-height (get start-time perm))
        (< block-height (get end-time perm))
      ))
      (ok false)
    )
  )
)

;; ============================================================================
;; SESSION MANAGEMENT
;; ============================================================================

;; Simplified session creation using counter-based IDs
(define-public (create-session
  (resource (string-ascii 64))
  (idle-timeout uint)
)
  (let (
    (session-id (var-get session-counter))
    (user-sessions (default-to { count: u0, max-sessions: u5 } (map-get? user-session-count { user: tx-sender })))
  )
    (begin
      (asserts! (< (get count user-sessions) (get max-sessions user-sessions)) ERR-SESSION-LIMIT-EXCEEDED)
      
      (map-set sessions
        { session-id: session-id, user: tx-sender }
        {
          created-at: block-height,
          last-activity: block-height,
          idle-timeout: idle-timeout,
          is-active: true,
          resource: resource
        }
      )
      
      (map-set user-session-count
        { user: tx-sender }
        { count: (+ (get count user-sessions) u1), max-sessions: (get max-sessions user-sessions) }
      )
      
      (var-set session-counter (+ session-id u1))
      (ok session-id)
    )
  )
)

;; Validate and update session activity
(define-public (validate-session (session-id uint))
  (let (
    (session (map-get? sessions { session-id: session-id, user: tx-sender }))
  )
    (match session
      sess (begin
        (asserts! (get is-active sess) ERR-SESSION-EXPIRED)
        (asserts! (< (- block-height (get last-activity sess)) (get idle-timeout sess)) ERR-SESSION-EXPIRED)
        
        (map-set sessions
          { session-id: session-id, user: tx-sender }
          (merge sess { last-activity: block-height })
        )
        (ok true)
      )
      ERR-SESSION-EXPIRED
    )
  )
)

;; End session
(define-public (end-session (session-id uint))
  (let (
    (session (map-get? sessions { session-id: session-id, user: tx-sender }))
    (user-sessions (unwrap! (map-get? user-session-count { user: tx-sender }) ERR-UNAUTHORIZED))
  )
    (match session
      sess (begin
        (map-set sessions
          { session-id: session-id, user: tx-sender }
          (merge sess { is-active: false })
        )
        
        (map-set user-session-count
          { user: tx-sender }
          { count: (- (get count user-sessions) u1), max-sessions: (get max-sessions user-sessions) }
        )
        (ok true)
      )
      ERR-SESSION-EXPIRED
    )
  )
)

;; Set maximum concurrent sessions for a user
(define-public (set-max-sessions (user principal) (max-sessions uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (asserts! (> max-sessions u0) ERR-INVALID-PARAMETERS)
    
    (map-set user-session-count
      { user: user }
      (merge
        (default-to { count: u0, max-sessions: u5 } (map-get? user-session-count { user: user }))
        { max-sessions: max-sessions }
      )
    )
    (ok true)
  )
)

;; ============================================================================
;; SCHEDULED OPERATIONS
;; ============================================================================

;; Simplified operation scheduling using counter-based IDs
(define-public (schedule-operation
  (operation-type (string-ascii 32))
  (scheduled-time uint)
  (data (buff 1024))
)
  (let (
    (operation-id (var-get operation-counter))
  )
    (asserts! (> scheduled-time block-height) ERR-INVALID-TIME)
    
    (map-set scheduled-operations
      { operation-id: operation-id }
      {
        user: tx-sender,
        operation-type: operation-type,
        scheduled-time: scheduled-time,
        execution-time: none,
        is-executed: false,
        is-cancelled: false,
        data: data,
        created-at: block-height
      }
    )
    
    (var-set operation-counter (+ operation-id u1))
    (ok operation-id)
  )
)

;; Execute a scheduled operation
(define-public (execute-scheduled-operation (operation-id uint))
  (let (
    (operation (unwrap! (map-get? scheduled-operations { operation-id: operation-id }) ERR-SCHEDULE-NOT-FOUND))
  )
    (asserts! (is-eq tx-sender (get user operation)) ERR-UNAUTHORIZED)
    (asserts! (not (get is-executed operation)) ERR-INVALID-PARAMETERS)
    (asserts! (not (get is-cancelled operation)) ERR-INVALID-PARAMETERS)
    (asserts! (>= block-height (get scheduled-time operation)) ERR-INVALID-TIME)
    
    (map-set scheduled-operations
      { operation-id: operation-id }
      (merge operation { is-executed: true, execution-time: (some block-height) })
    )
    (ok true)
  )
)

;; Cancel a scheduled operation
(define-public (cancel-scheduled-operation (operation-id uint))
  (let (
    (operation (unwrap! (map-get? scheduled-operations { operation-id: operation-id }) ERR-SCHEDULE-NOT-FOUND))
  )
    (asserts! (or (is-eq tx-sender (get user operation)) (is-eq tx-sender CONTRACT-OWNER)) ERR-UNAUTHORIZED)
    (asserts! (not (get is-executed operation)) ERR-INVALID-PARAMETERS)
    
    (map-set scheduled-operations
      { operation-id: operation-id }
      (merge operation { is-cancelled: true })
    )
    (ok true)
  )
)

;; ============================================================================
;; RECURRING PERMISSIONS
;; ============================================================================

;; Simplified recurring permission creation using counter-based IDs
(define-public (create-recurring-permission
  (user principal)
  (resource (string-ascii 64))
  (interval uint)
  (start-time uint)
  (end-time (optional uint))
  (access-level uint)
)
  (let (
    (pattern-id (var-get pattern-counter))
  )
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (asserts! (> interval u0) ERR-INVALID-PARAMETERS)
    
    (map-set recurring-permissions
      { user: user, pattern-id: pattern-id }
      {
        resource: resource,
        interval: interval,
        start-time: start-time,
        end-time: end-time,
        access-level: access-level,
        is-active: true,
        created-at: block-height
      }
    )
    
    (var-set pattern-counter (+ pattern-id u1))
    (ok pattern-id)
  )
)

;; Deactivate recurring permission
(define-public (deactivate-recurring-permission
  (user principal)
  (pattern-id uint)
)
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (asserts! (is-some (map-get? recurring-permissions { user: user, pattern-id: pattern-id })) ERR-PERMISSION-NOT-FOUND)
    
    (map-set recurring-permissions
      { user: user, pattern-id: pattern-id }
      (merge
        (unwrap! (map-get? recurring-permissions { user: user, pattern-id: pattern-id }) ERR-PERMISSION-NOT-FOUND)
        { is-active: false }
      )
    )
    (ok true)
  )
)

;; ============================================================================
;; EMERGENCY TIME EXTENSIONS
;; ============================================================================

;; Request emergency time extension
(define-public (request-emergency-extension
  (resource (string-ascii 64))
  (extension-duration uint)
  (reason (string-ascii 128))
)
  (let (
    (permission (unwrap! (map-get? temporal-permissions { user: tx-sender, resource: resource }) ERR-PERMISSION-NOT-FOUND))
    (new-end-time (+ (get end-time permission) extension-duration))
  )
    (asserts! (get is-active permission) ERR-PERMISSION-EXPIRED)
    
    (map-set emergency-extensions
      { user: tx-sender, resource: resource }
      {
        original-end-time: (get end-time permission),
        extended-end-time: new-end-time,
        extension-reason: reason,
        approved-by: CONTRACT-OWNER,
        created-at: block-height
      }
    )
    
    (map-set temporal-permissions
      { user: tx-sender, resource: resource }
      (merge permission { end-time: new-end-time })
    )
    
    (ok true)
  )
)

;; ============================================================================
;; READ-ONLY FUNCTIONS
;; ============================================================================

;; Get permission details
(define-read-only (get-permission
  (user principal)
  (resource (string-ascii 64))
)
  (map-get? temporal-permissions { user: user, resource: resource })
)

;; Get session details
(define-read-only (get-session (session-id uint) (user principal))
  (map-get? sessions { session-id: session-id, user: user })
)

;; Get user session count
(define-read-only (get-user-session-count (user principal))
  (map-get? user-session-count { user: user })
)

;; Get scheduled operation details
(define-read-only (get-scheduled-operation (operation-id uint))
  (map-get? scheduled-operations { operation-id: operation-id })
)

;; Get emergency extension details
(define-read-only (get-emergency-extension
  (user principal)
  (resource (string-ascii 64))
)
  (map-get? emergency-extensions { user: user, resource: resource })
)
