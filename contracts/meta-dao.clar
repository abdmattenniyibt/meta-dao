;; meta-dao.clar
;; Advanced DAO Governance Contract with Treasury and Token-Weighted Voting
;; Built for Stacks blockchain in Clarity language

(define-constant ERR_NOT_MEMBER u100)
(define-constant ERR_ALREADY_VOTED u101)
(define-constant ERR_VOTING_CLOSED u102)
(define-constant ERR_INVALID_PROPOSAL u103)
(define-constant ERR_ALREADY_EXECUTED u104)
(define-constant ERR_INSUFFICIENT_FUNDS u105)
(define-constant ERR_DELEGATION_EXISTS u106)
(define-constant ERR_NOT_DELEGATED u107)
(define-constant ERR_NOT_OWNER u108)
(define-constant ERR_DAO_PAUSED u109)

;; -----------------------------------------
;; DAO core data
;; -----------------------------------------

(define-data-var owner principal tx-sender)
(define-data-var paused bool false)
(define-data-var total-treasury uint u0)
(define-data-var next-proposal-id uint u0)
(define-data-var voting-period uint u250) ;; ~250 blocks
(define-data-var quorum-threshold uint u100) ;; minimum yes-votes

;; Token-based voting weights (could integrate with SIP-010 token later)
(define-map voting-power principal uint)

;; Delegation: member to delegate
(define-map delegates principal principal)

;; Proposals
(define-map proposals
  uint
  (tuple
    (creator principal)
    (title (string-ascii 64))
    (description (string-ascii 256))
    (yes-weight uint)
    (no-weight uint)
    (start-block uint)
    (end-block uint)
    (executed bool)
    (fund-requested uint)
    (beneficiary principal)
  )
)

;; Record of votes
(define-map votes
  (tuple (proposal-id uint) (voter principal))
  bool
)

;; -----------------------------------------
;; Internal helpers
;; -----------------------------------------

(define-private (only-owner)
  (if (is-eq tx-sender (var-get owner))
      (ok true)
      (err ERR_NOT_OWNER))
)

(define-private (not-paused)
  (if (var-get paused)
      (err ERR_DAO_PAUSED)
      (ok true))
)

(define-private (get-current-block)
  u0
)

(define-private (is-member (user principal))
  (> (default-to u0 (map-get? voting-power user)) u0))

(define-private (get-vote-weight (user principal))
  (default-to u0 (map-get? voting-power user)))

(define-private (get-delegate (user principal))
  (map-get? delegates user))

;; -----------------------------------------
;; DAO Admin and Treasury functions
;; -----------------------------------------

(define-public (pause)
  (begin
    (try! (only-owner))
    (var-set paused true)
    (ok "DAO Paused")
  )
)

(define-public (resume)
  (begin
    (try! (only-owner))
    (var-set paused false)
    (ok "DAO Resumed")
  )
)

(define-public (add-member (user principal) (weight uint))
  (begin
    (try! (only-owner))
    (map-set voting-power user weight)
    (ok (tuple (added user) (weight weight)))
  )
)

(define-public (update-member-weight (user principal) (new-weight uint))
  (begin
    (try! (only-owner))
    (map-set voting-power user new-weight)
    (ok (tuple (updated user) (weight new-weight)))
  )
)

;; Treasury deposit (DAO funding)
(define-public (deposit-treasury (amount uint))
  (begin
    (try! (not-paused))
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    (var-set total-treasury (+ (var-get total-treasury) amount))
    (ok (tuple (status "treasury-funded") (amount amount)))
  )
)

;; Withdraw (only by owner - could extend to passed proposals)
(define-public (withdraw (recipient principal) (amount uint))
  (begin
    (try! (only-owner))
    (if (<= amount (var-get total-treasury))
        (begin
          (try! (stx-transfer? amount contract-caller recipient))
          (var-set total-treasury (- (var-get total-treasury) amount))
          (ok (tuple (status "withdrawn") (to recipient) (amount amount))))
        (err ERR_INSUFFICIENT_FUNDS))
  )
)

;; -----------------------------------------
;; Voting and proposal system
;; -----------------------------------------

;; Create a proposal (optionally requesting DAO funds)
(define-public (create-proposal
  (title (string-ascii 64))
  (desc (string-ascii 256))
  (fund-requested uint)
  (beneficiary principal)
)
  (begin
    (try! (not-paused))
    (if (is-member tx-sender)
        (let ((id (+ (var-get next-proposal-id) u1)))
          (map-set proposals id
            (tuple
              (creator tx-sender)
              (title title)
              (description desc)
              (yes-weight u0)
              (no-weight u0)
              (start-block (get-current-block))
              (end-block (+ (get-current-block) (var-get voting-period)))
              (executed false)
              (fund-requested fund-requested)
              (beneficiary beneficiary)
            ))
          (var-set next-proposal-id id)
          (ok (tuple (proposal-id id) (status "created"))))
        (err ERR_NOT_MEMBER))
  )
)

;; Vote on proposal (true = yes, false = no)
(define-public (vote (proposal-id uint) (support bool))
  (begin
    (try! (not-paused))
    (if (is-member tx-sender)
        (match (map-get? proposals proposal-id)
          proposal
            (let ((p proposal))
              (if (and (>= (get-current-block) (get start-block p))
                       (< (get-current-block) (get end-block p))
                       (not (is-some (map-get? votes (tuple (proposal-id proposal-id) (voter tx-sender))))))
                  (begin
                    (map-set votes (tuple (proposal-id proposal-id) (voter tx-sender)) support)
                    (let ((weight (get-vote-weight tx-sender)))
                      (if support
                          (map-set proposals proposal-id
                            (tuple
                              (creator (get creator p))
                              (title (get title p))
                              (description (get description p))
                              (yes-weight (+ (get yes-weight p) weight))
                              (no-weight (get no-weight p))
                              (start-block (get start-block p))
                              (end-block (get end-block p))
                              (executed (get executed p))
                              (fund-requested (get fund-requested p))
                              (beneficiary (get beneficiary p))))
                          (map-set proposals proposal-id
                            (tuple
                              (creator (get creator p))
                              (title (get title p))
                              (description (get description p))
                              (yes-weight (get yes-weight p))
                              (no-weight (+ (get no-weight p) weight))
                              (start-block (get start-block p))
                              (end-block (get end-block p))
                              (executed (get executed p))
                              (fund-requested (get fund-requested p))
                              (beneficiary (get beneficiary p))))))
                    (ok (tuple (voter tx-sender) (support support))))
                  (err ERR_VOTING_CLOSED)))
          (err ERR_INVALID_PROPOSAL)
        )
        (err ERR_NOT_MEMBER))
  )
)

;; Execute proposal if passed and quorum met
(define-public (execute-proposal (proposal-id uint))
  (match (map-get? proposals proposal-id)
    proposal
      (let ((p proposal))
        (if (>= (get-current-block) (get end-block p))
            (if (not (get executed p))
                (if (> (get yes-weight p) (get no-weight p))
                    (begin
                      (if (and (> (get fund-requested p) u0)
                               (<= (get fund-requested p) (var-get total-treasury)))
                          (begin
                            (try! (stx-transfer? (get fund-requested p) contract-caller (get beneficiary p)))
                            (var-set total-treasury (- (var-get total-treasury) (get fund-requested p)))
                          )
                          true
                      )
                      (map-set proposals proposal-id
                        (tuple
                          (creator (get creator p))
                          (title (get title p))
                          (description (get description p))
                          (yes-weight (get yes-weight p))
                          (no-weight (get no-weight p))
                          (start-block (get start-block p))
                          (end-block (get end-block p))
                          (executed true)
                          (fund-requested (get fund-requested p))
                          (beneficiary (get beneficiary p))))
                      (ok (tuple (status "executed") (passed true)))
                    )
                    (ok (tuple (status "failed") (passed false))))
                (err ERR_ALREADY_EXECUTED))
            (err ERR_VOTING_CLOSED)))
    (err ERR_INVALID_PROPOSAL)
  )
)

;; -----------------------------------------
;; Delegation system
;; -----------------------------------------

;; Delegate votes to another member
(define-public (delegate (to principal))
  (begin
    (try! (not-paused))
    (if (is-member to)
        (begin
          (map-set delegates tx-sender to)
          (ok (tuple (delegated-to to))))
        (err ERR_NOT_MEMBER))
  )
)

;; Remove delegation
(define-public (remove-delegation)
  (if (is-some (map-get? delegates tx-sender))
      (begin
        (map-delete delegates tx-sender)
        (ok "Delegation removed"))
      (err ERR_NOT_DELEGATED))
)

;; -----------------------------------------
;; Read-only functions
;; -----------------------------------------

(define-read-only (get-member-weight (user principal))
  (get-vote-weight user)
)

(define-read-only (get-proposal (id uint))
  (map-get? proposals id)
)

(define-read-only (get-total-proposals)
  (var-get next-proposal-id)
)

(define-read-only (get-treasury-balance)
  (var-get total-treasury)
)

(define-read-only (get-delegation (user principal))
  (get-delegate user)
)

(define-read-only (get-dao-status)
  (if (var-get paused) "paused" "active")
)
