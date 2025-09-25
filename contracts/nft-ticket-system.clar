;; NFT Event Ticketing System
;; Issue NFT tickets, prevent unauthorized resale, and manage event access
;; Anti-scalping marketplace for authentic event tickets

;; constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-EVENT-NOT-FOUND (err u101))
(define-constant ERR-TICKET-NOT-FOUND (err u102))
(define-constant ERR-ALREADY-EXISTS (err u103))
(define-constant ERR-INSUFFICIENT-FUNDS (err u104))
(define-constant ERR-TRANSFER-NOT-ALLOWED (err u105))
(define-constant ERR-EVENT-FULL (err u106))
(define-constant ERR-INVALID-PRICE (err u107))
(define-constant ERR-NOT-OWNER (err u108))
(define-constant ERR-EVENT-EXPIRED (err u109))
(define-constant ERR-TICKET-USED (err u110))

;; Event status constants
(define-constant EVENT-ACTIVE u1)
(define-constant EVENT-CANCELLED u2)
(define-constant EVENT-COMPLETED u3)

;; Ticket status constants
(define-constant TICKET-AVAILABLE u1)
(define-constant TICKET-SOLD u2)
(define-constant TICKET-USED u3)
(define-constant TICKET-REFUNDED u4)

;; Transfer restriction types
(define-constant TRANSFER-FORBIDDEN u0)
(define-constant TRANSFER-RESTRICTED u1)
(define-constant TRANSFER-ALLOWED u2)

;; data maps and vars
;; Event registry with comprehensive details
(define-map events
  { event-id: (string-ascii 64) }
  {
    organizer: principal,
    name: (string-ascii 128),
    description: (string-ascii 512),
    venue: (string-ascii 256),
    event-date: uint,
    total-capacity: uint,
    tickets-sold: uint,
    base-price: uint,
    max-resale-price: uint,
    status: uint,
    created-at: uint,
    transfer-policy: uint,
    revenue-earned: uint,
    platform-fee-rate: uint
  }
)

;; NFT ticket registry
(define-map tickets
  { ticket-id: uint }
  {
    event-id: (string-ascii 64),
    owner: principal,
    seat-section: (string-ascii 64),
    original-price: uint,
    current-price: uint,
    purchase-date: uint,
    status: uint,
    transfer-count: uint,
    metadata-uri: (string-ascii 256),
    access-code: (string-ascii 128),
    used-at: (optional uint)
  }
)

;; Ticket ownership tracking for NFT standard compliance
(define-map ticket-owners
  { ticket-id: uint }
  { owner: principal }
)

;; Event organizer registry
(define-map event-organizers
  { organizer: principal }
  {
    name: (string-ascii 128),
    verification-status: bool,
    events-created: uint,
    total-revenue: uint,
    reputation-score: uint,
    joined-at: uint
  }
)

;; Transfer history for anti-scalping tracking
(define-map transfer-history
  { ticket-id: uint, transfer-index: uint }
  {
    from-owner: principal,
    to-owner: principal,
    transfer-date: uint,
    price-paid: uint,
    platform-fee: uint,
    reason: (string-ascii 128)
  }
)

;; Access validation logs
(define-map access-logs
  { ticket-id: uint }
  {
    validated-at: uint,
    validator: principal,
    event-id: (string-ascii 64),
    access-granted: bool
  }
)

;; Platform statistics
(define-data-var next-ticket-id uint u1)
(define-data-var total-events uint u0)
(define-data-var total-tickets-sold uint u0)
(define-data-var total-revenue uint u0)
(define-data-var platform-fee-rate uint u250) ;; 2.5%
(define-data-var max-resale-markup uint u150) ;; 150% of original price

;; private functions
;; Validate event organizer authorization
(define-private (is-authorized-organizer (organizer principal))
  (match (map-get? event-organizers {organizer: organizer})
    org-data (get verification-status org-data)
    false
  )
)

;; Calculate platform fee for transaction
(define-private (calculate-platform-fee (amount uint))
  (/ (* amount (var-get platform-fee-rate)) u10000)
)

;; Validate transfer restrictions
(define-private (can-transfer-ticket 
    (ticket-id uint)
    (from-owner principal)
    (to-owner principal)
    (proposed-price uint))
  (match (map-get? tickets {ticket-id: ticket-id})
    ticket
    (match (map-get? events {event-id: (get event-id ticket)})
      event
      (let (
        (transfer-policy (get transfer-policy event))
        (max-price (get max-resale-price event))
        (is-owner (is-eq from-owner (get owner ticket)))
        (price-valid (<= proposed-price max-price))
      )
        (and 
          is-owner
          (not (is-eq transfer-policy TRANSFER-FORBIDDEN))
          (or (is-eq transfer-policy TRANSFER-ALLOWED) price-valid)
          (not (is-eq (get status ticket) TICKET-USED))
        )
      )
      false
    )
    false
  )
)

;; Update organizer statistics
(define-private (update-organizer-stats (organizer principal) (revenue uint))
  (match (map-get? event-organizers {organizer: organizer})
    current-data
    (map-set event-organizers
      {organizer: organizer}
      (merge current-data {
        total-revenue: (+ (get total-revenue current-data) revenue),
        reputation-score: (if (< (get reputation-score current-data) u100)
                            (+ (get reputation-score current-data) u1)
                            u100)
      })
    )
    false
  )
)

;; Generate access code for ticket
(define-private (generate-access-code (ticket-id uint) (event-id (string-ascii 64)))
  ;; Simplified access code generation (in production, use proper randomization)
  (concat "ACCESS-" (concat event-id (int-to-ascii ticket-id)))
)

;; public functions
;; Register as event organizer
(define-public (register-organizer (name (string-ascii 128)))
  (let (
    (organizer tx-sender)
  )
    (asserts! (is-none (map-get? event-organizers {organizer: organizer})) ERR-ALREADY-EXISTS)
    (map-set event-organizers
      {organizer: organizer}
      {
        name: name,
        verification-status: true, ;; Auto-verify for demo
        events-created: u0,
        total-revenue: u0,
        reputation-score: u50,
        joined-at: stacks-block-height
      }
    )
    (ok true)
  )
)

;; Create a new event
(define-public (create-event
    (event-id (string-ascii 64))
    (name (string-ascii 128))
    (description (string-ascii 512))
    (venue (string-ascii 256))
    (event-date uint)
    (total-capacity uint)
    (base-price uint)
    (transfer-policy uint))
  (let (
    (organizer tx-sender)
    (max-resale (+ base-price (/ (* base-price (var-get max-resale-markup)) u100)))
  )
    (asserts! (is-authorized-organizer organizer) ERR-NOT-AUTHORIZED)
    (asserts! (is-none (map-get? events {event-id: event-id})) ERR-ALREADY-EXISTS)
    (asserts! (>= event-date stacks-block-height) ERR-EVENT-EXPIRED)
    (asserts! (> total-capacity u0) ERR-INVALID-PRICE)
    (asserts! (> base-price u0) ERR-INVALID-PRICE)
    
    (map-set events
      {event-id: event-id}
      {
        organizer: organizer,
        name: name,
        description: description,
        venue: venue,
        event-date: event-date,
        total-capacity: total-capacity,
        tickets-sold: u0,
        base-price: base-price,
        max-resale-price: max-resale,
        status: EVENT-ACTIVE,
        created-at: stacks-block-height,
        transfer-policy: transfer-policy,
        revenue-earned: u0,
        platform-fee-rate: (var-get platform-fee-rate)
      }
    )
    
    ;; Update organizer stats
    (match (map-get? event-organizers {organizer: organizer})
      org-data
      (map-set event-organizers
        {organizer: organizer}
        (merge org-data {
          events-created: (+ (get events-created org-data) u1)
        })
      )
      false
    )
    
    (var-set total-events (+ (var-get total-events) u1))
    (ok event-id)
  )
)

;; Mint a ticket for an event
(define-public (mint-ticket
    (event-id (string-ascii 64))
    (seat-section (string-ascii 64))
    (metadata-uri (string-ascii 256)))
  (let (
    (ticket-id (var-get next-ticket-id))
    (buyer tx-sender)
  )
    (match (map-get? events {event-id: event-id})
      event
      (let (
        (ticket-price (get base-price event))
        (platform-fee (calculate-platform-fee ticket-price))
        (organizer-payment (- ticket-price platform-fee))
        (access-code (generate-access-code ticket-id event-id))
      )
        (asserts! (is-eq (get status event) EVENT-ACTIVE) ERR-EVENT-EXPIRED)
        (asserts! (< (get tickets-sold event) (get total-capacity event)) ERR-EVENT-FULL)
        (asserts! (>= (stx-get-balance buyer) ticket-price) ERR-INSUFFICIENT-FUNDS)
        
        ;; Transfer payment
        (try! (stx-transfer? organizer-payment buyer (get organizer event)))
        (try! (stx-transfer? platform-fee buyer CONTRACT-OWNER))
        
        ;; Create ticket NFT
        (map-set tickets
          {ticket-id: ticket-id}
          {
            event-id: event-id,
            owner: buyer,
            seat-section: seat-section,
            original-price: ticket-price,
            current-price: ticket-price,
            purchase-date: stacks-block-height,
            status: TICKET-SOLD,
            transfer-count: u0,
            metadata-uri: metadata-uri,
            access-code: access-code,
            used-at: none
          }
        )
        
        ;; Set NFT ownership
        (map-set ticket-owners
          {ticket-id: ticket-id}
          {owner: buyer}
        )
        
        ;; Update event statistics
        (map-set events
          {event-id: event-id}
          (merge event {
            tickets-sold: (+ (get tickets-sold event) u1),
            revenue-earned: (+ (get revenue-earned event) ticket-price)
          })
        )
        
        ;; Update platform statistics
        (var-set next-ticket-id (+ ticket-id u1))
        (var-set total-tickets-sold (+ (var-get total-tickets-sold) u1))
        (var-set total-revenue (+ (var-get total-revenue) ticket-price))
        
        ;; Update organizer stats
        (update-organizer-stats (get organizer event) organizer-payment)
        
        (ok ticket-id)
      )
      ERR-EVENT-NOT-FOUND
    )
  )
)

;; Transfer ticket with anti-scalping controls
(define-public (transfer-ticket
    (ticket-id uint)
    (to-owner principal)
    (price uint)
    (reason (string-ascii 128)))
  (let (
    (from-owner tx-sender)
  )
    (asserts! (can-transfer-ticket ticket-id from-owner to-owner price) ERR-TRANSFER-NOT-ALLOWED)
    (asserts! (>= (stx-get-balance to-owner) price) ERR-INSUFFICIENT-FUNDS)
    
    (match (map-get? tickets {ticket-id: ticket-id})
      ticket
      (let (
        (platform-fee (calculate-platform-fee price))
        (seller-payment (- price platform-fee))
        (transfer-index (get transfer-count ticket))
      )
        ;; Transfer payment
        (try! (stx-transfer? seller-payment to-owner from-owner))
        (try! (stx-transfer? platform-fee to-owner CONTRACT-OWNER))
        
        ;; Update ticket ownership
        (map-set tickets
          {ticket-id: ticket-id}
          (merge ticket {
            owner: to-owner,
            current-price: price,
            transfer-count: (+ transfer-index u1)
          })
        )
        
        (map-set ticket-owners
          {ticket-id: ticket-id}
          {owner: to-owner}
        )
        
        ;; Record transfer history
        (map-set transfer-history
          {ticket-id: ticket-id, transfer-index: transfer-index}
          {
            from-owner: from-owner,
            to-owner: to-owner,
            transfer-date: stacks-block-height,
            price-paid: price,
            platform-fee: platform-fee,
            reason: reason
          }
        )
        
        (ok true)
      )
      ERR-TICKET-NOT-FOUND
    )
  )
)

;; Validate ticket for event access
(define-public (validate-access
    (ticket-id uint)
    (event-id (string-ascii 64)))
  (let (
    (validator tx-sender)
  )
    (match (map-get? tickets {ticket-id: ticket-id})
      ticket
      (let (
        (is-valid-event (is-eq (get event-id ticket) event-id))
        (is-not-used (is-eq (get status ticket) TICKET-SOLD))
        (access-granted (and is-valid-event is-not-used))
      )
        (if access-granted
            (begin
              ;; Mark ticket as used
              (map-set tickets
                {ticket-id: ticket-id}
                (merge ticket {
                  status: TICKET-USED,
                  used-at: (some stacks-block-height)
                })
              )
              
              ;; Log access validation
              (map-set access-logs
                {ticket-id: ticket-id}
                {
                  validated-at: stacks-block-height,
                  validator: validator,
                  event-id: event-id,
                  access-granted: true
                }
              )
            )
            ;; Log failed validation
            (map-set access-logs
              {ticket-id: ticket-id}
              {
                validated-at: stacks-block-height,
                validator: validator,
                event-id: event-id,
                access-granted: false
              }
            )
        )
        
        (ok access-granted)
      )
      ERR-TICKET-NOT-FOUND
    )
  )
)

;; Get event information
(define-public (get-event-info (event-id (string-ascii 64)))
  (ok (map-get? events {event-id: event-id}))
)

;; Get ticket information
(define-public (get-ticket-info (ticket-id uint))
  (ok (map-get? tickets {ticket-id: ticket-id}))
)

;; Get ticket owner (NFT standard compliance)
(define-public (get-owner (ticket-id uint))
  (ok (get owner (default-to {owner: CONTRACT-OWNER} (map-get? ticket-owners {ticket-id: ticket-id}))))
)

;; Get organizer information
(define-public (get-organizer-info (organizer principal))
  (ok (map-get? event-organizers {organizer: organizer}))
)

;; read only functions
;; Get platform statistics
(define-read-only (get-platform-stats)
  {
    total-events: (var-get total-events),
    total-tickets-sold: (var-get total-tickets-sold),
    total-revenue: (var-get total-revenue),
    platform-fee-rate: (var-get platform-fee-rate)
  }
)

;; Check if ticket can be transferred
(define-read-only (can-transfer (ticket-id uint) (from-owner principal) (to-owner principal) (price uint))
  (can-transfer-ticket ticket-id from-owner to-owner price)
)

;; Get transfer history
(define-read-only (get-transfer-history (ticket-id uint) (transfer-index uint))
  (map-get? transfer-history {ticket-id: ticket-id, transfer-index: transfer-index})
)

;; Get access log
(define-read-only (get-access-log (ticket-id uint))
  (map-get? access-logs {ticket-id: ticket-id})
)

;; Check event availability
(define-read-only (get-event-availability (event-id (string-ascii 64)))
  (match (map-get? events {event-id: event-id})
    event {
      available-tickets: (- (get total-capacity event) (get tickets-sold event)),
      total-capacity: (get total-capacity event),
      tickets-sold: (get tickets-sold event),
      base-price: (get base-price event)
    }
    {available-tickets: u0, total-capacity: u0, tickets-sold: u0, base-price: u0}
  )
)
