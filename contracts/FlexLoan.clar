;; FlexLoan - Dynamic Interest Rate Lending Protocol
;; A decentralized lending platform with credit scoring and dynamic rates

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u100))
(define-constant ERR_INSUFFICIENT_BALANCE (err u101))
(define-constant ERR_LOAN_NOT_FOUND (err u102))
(define-constant ERR_LOAN_ALREADY_EXISTS (err u103))
(define-constant ERR_INVALID_AMOUNT (err u104))
(define-constant ERR_INSUFFICIENT_COLLATERAL (err u105))
(define-constant ERR_LOAN_OVERDUE (err u106))

;; Data Variables
(define-data-var loan-counter uint u0)
(define-data-var total-liquidity uint u0)
(define-data-var base-interest-rate uint u500) ;; 5% in basis points

;; Data Maps
(define-map loans
  { loan-id: uint }
  {
    borrower: principal,
    amount: uint,
    collateral: uint,
    interest-rate: uint,
    created-at: uint,
    due-date: uint,
    is-active: bool
  }
)

(define-map user-credit-scores
  { user: principal }
  { score: uint, total-borrowed: uint, total-repaid: uint, defaults: uint }
)

(define-map liquidity-providers
  { provider: principal }
  { amount: uint, rewards-earned: uint }
)

;; Read-only functions
(define-read-only (get-loan (loan-id uint))
  (map-get? loans { loan-id: loan-id })
)

(define-read-only (get-credit-score (user principal))
  (default-to 
    { score: u500, total-borrowed: u0, total-repaid: u0, defaults: u0 }
    (map-get? user-credit-scores { user: user })
  )
)

(define-read-only (get-liquidity-provider (provider principal))
  (map-get? liquidity-providers { provider: provider })
)

(define-read-only (calculate-interest-rate (borrower principal) (collateral-ratio uint))
  (let (
    (credit-data (get-credit-score borrower))
    (base-rate (var-get base-interest-rate))
    (credit-score (get score credit-data))
    (risk-adjustment (if (< credit-score u600) u200 u0))
    (collateral-adjustment (if (< collateral-ratio u150) u100 u0))
  )
    (+ base-rate risk-adjustment collateral-adjustment)
  )
)

(define-read-only (get-total-liquidity)
  (var-get total-liquidity)
)

(define-read-only (get-loan-counter)
  (var-get loan-counter)
)

;; Public functions
(define-public (provide-liquidity (amount uint))
  (let (
    (current-provider (get-liquidity-provider tx-sender))
    (current-amount (default-to u0 (get amount current-provider)))
  )
    (asserts! (> amount u0) ERR_INVALID_AMOUNT)
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    (map-set liquidity-providers
      { provider: tx-sender }
      { 
        amount: (+ current-amount amount),
        rewards-earned: (default-to u0 (get rewards-earned current-provider))
      }
    )
    (var-set total-liquidity (+ (var-get total-liquidity) amount))
    (ok amount)
  )
)

(define-public (request-loan (amount uint) (collateral uint) (duration-blocks uint))
  (let (
    (loan-id (+ (var-get loan-counter) u1))
    (collateral-ratio (/ (* collateral u100) amount))
    (interest-rate (calculate-interest-rate tx-sender collateral-ratio))
    (due-date (+ block-height duration-blocks))
  )
    (asserts! (> amount u0) ERR_INVALID_AMOUNT)
    (asserts! (>= collateral-ratio u120) ERR_INSUFFICIENT_COLLATERAL)
    (asserts! (<= amount (var-get total-liquidity)) ERR_INSUFFICIENT_BALANCE)
    (asserts! (is-none (get-loan loan-id)) ERR_LOAN_ALREADY_EXISTS)

    ;; Transfer collateral from borrower
    (try! (stx-transfer? collateral tx-sender (as-contract tx-sender)))

    ;; Transfer loan amount to borrower
    (try! (as-contract (stx-transfer? amount tx-sender tx-sender)))

    ;; Create loan record
    (map-set loans
      { loan-id: loan-id }
      {
        borrower: tx-sender,
        amount: amount,
        collateral: collateral,
        interest-rate: interest-rate,
        created-at: block-height,
        due-date: due-date,
        is-active: true
      }
    )

    ;; Update loan counter and liquidity
    (var-set loan-counter loan-id)
    (var-set total-liquidity (- (var-get total-liquidity) amount))

    (ok loan-id)
  )
)

(define-public (repay-loan (loan-id uint))
  (let (
    (loan-data (unwrap! (get-loan loan-id) ERR_LOAN_NOT_FOUND))
    (borrower (get borrower loan-data))
    (amount (get amount loan-data))
    (collateral (get collateral loan-data))
    (interest-rate (get interest-rate loan-data))
    (interest-amount (/ (* amount interest-rate) u10000))
    (total-repayment (+ amount interest-amount))
    (credit-data (get-credit-score borrower))
  )
    (asserts! (get is-active loan-data) ERR_LOAN_NOT_FOUND)
    (asserts! (is-eq tx-sender borrower) ERR_UNAUTHORIZED)

    ;; Transfer repayment from borrower
    (try! (stx-transfer? total-repayment tx-sender (as-contract tx-sender)))

    ;; Return collateral to borrower
    (try! (as-contract (stx-transfer? collateral tx-sender borrower)))

    ;; Update loan status
    (map-set loans
      { loan-id: loan-id }
      (merge loan-data { is-active: false })
    )

    ;; Update credit score
    (map-set user-credit-scores
      { user: borrower }
      {
        score: (if (> (+ (get score credit-data) u10) u850) u850 (+ (get score credit-data) u10)),
        total-borrowed: (+ (get total-borrowed credit-data) amount),
        total-repaid: (+ (get total-repaid credit-data) total-repayment),
        defaults: (get defaults credit-data)
      }
    )

    ;; Add back to liquidity pool
    (var-set total-liquidity (+ (var-get total-liquidity) total-repayment))

    (ok total-repayment)
  )
)

(define-public (liquidate-loan (loan-id uint))
  (let (
    (loan-data (unwrap! (get-loan loan-id) ERR_LOAN_NOT_FOUND))
    (borrower (get borrower loan-data))
    (collateral (get collateral loan-data))
    (due-date (get due-date loan-data))
    (credit-data (get-credit-score borrower))
  )
    (asserts! (get is-active loan-data) ERR_LOAN_NOT_FOUND)
    (asserts! (> block-height due-date) ERR_LOAN_OVERDUE)

    ;; Transfer collateral to liquidator as reward
    (try! (as-contract (stx-transfer? collateral tx-sender tx-sender)))

    ;; Update loan status
    (map-set loans
      { loan-id: loan-id }
      (merge loan-data { is-active: false })
    )

    ;; Update borrower credit score (penalty for default)
    (map-set user-credit-scores
      { user: borrower }
      {
        score: (if (> (get score credit-data) u50) (- (get score credit-data) u50) u0),
        total-borrowed: (+ (get total-borrowed credit-data) (get amount loan-data)),
        total-repaid: (get total-repaid credit-data),
        defaults: (+ (get defaults credit-data) u1)
      }
    )

    (ok collateral)
  )
)

(define-public (withdraw-liquidity (amount uint))
  (let (
    (provider-data (unwrap! (get-liquidity-provider tx-sender) ERR_UNAUTHORIZED))
    (provider-amount (get amount provider-data))
  )
    (asserts! (>= provider-amount amount) ERR_INSUFFICIENT_BALANCE)
    (asserts! (>= (var-get total-liquidity) amount) ERR_INSUFFICIENT_BALANCE)

    ;; Transfer amount to provider
    (try! (as-contract (stx-transfer? amount tx-sender tx-sender)))

    ;; Update provider record
    (map-set liquidity-providers
      { provider: tx-sender }
      (merge provider-data { amount: (- provider-amount amount) })
    )

    ;; Update total liquidity
    (var-set total-liquidity (- (var-get total-liquidity) amount))

    (ok amount)
  )
)
