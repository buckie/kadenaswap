(namespace (read-msg 'ns))

(module pool GOVERNANCE

  (defcap GOVERNANCE ()
    (enforce-guard (keyset-ref-guard 'relay-admin-keyset))
  )

  (defconst DAY:integer (* 24 (* 60 60)))

  (use util.guards)

  (defschema pool-schema
    token:module{fungible-v2}
    account:string
    bonded:decimal
    service:decimal
    lockup:integer
    bond:decimal
    active:[string]
    activity:integer
    endorsers:integer
    denouncers:integer
    confirm:decimal
    rate:decimal
    fee:decimal
    guard:guard
  )
  (deftable pools:{pool-schema})

  (defun get-pool:object{pool-schema} (id:string)
    (read pools id))

  (defschema bond-schema
    pool:string
    guard:guard
    balance:decimal
    date:time
    lockup:integer
    activity:integer
  )

  (deftable bonds:{bond-schema})

  (defun get-bond:object{bond-schema} (id:string)
    (read bonds id))

  (defcap POOL_ADMIN ()
    (compose-capability (GOVERNANCE)))

  (defcap WITHDRAW (bond:string)
    @managed
    (enforce-guard (at 'guard (get-bond bond)))
  )

  (defun pool-guard () (create-module-guard "pool-bank"))

  (defun init-pool
    ( pool:string
      token:module{fungible-v2}
      account:string
      lockup:integer
      bond:decimal
      activity:integer
      endorsers:integer
      denouncers:integer
      confirm:decimal
      rate:decimal
      fee:decimal
      guard:guard
    )
    (with-capability (POOL_ADMIN)
      (token::create-account account (pool-guard))
      (insert pools pool
        { 'token: token
        , 'account: account
        , 'bonded: 0.0
        , 'service: 0.0
        , 'lockup: lockup
        , 'bond: bond
        , 'active: []
        , 'activity: activity
        , 'endorsers:endorsers
        , 'denouncers:denouncers
        , 'confirm:confirm
        , 'rate: rate
        , 'fee: fee
        , 'guard: guard
        })))

  (defun update-pool
    ( pool:string
      lockup:integer
      bond:decimal
      activity:integer
      endorsers:integer
      denouncers:integer
      confirm:decimal
      rate:decimal
      fee:decimal
    )
    (with-capability (POOL_ADMIN)
      (update pools pool
        { 'lockup: lockup
        , 'bond: bond
        , 'activity: activity
        , 'endorsers:endorsers
        , 'denouncers:denouncers
        , 'confirm:confirm
        , 'rate: rate
        , 'fee: fee
        })))

  (defun fund-service
    ( pool:string
      account:string
      amount:decimal
    )
    (with-read pools pool
      { 'token:= token:module{fungible-v2}
      , 'service:= service
      , 'account:= pool-account }
      (token::transfer account pool-account amount)
      (update pools pool { 'service: (+ service amount) }))
  )

  (defun withdraw-service
    ( pool:string
      account:string
      amount:decimal )
    (with-capability (POOL_ADMIN)
      (with-read pools pool
        { 'token:=token:module{fungible-v2}
        , 'service:=service
        , 'account:=pool-account
        }
        (install-capability (token::TRANSFER pool-account account amount))
        (token::transfer pool-account account amount)
        (update pools pool { 'service:(- service amount)})))
  )

  (defun new-bond:string
    ( pool:string
      account:string
      guard:guard
    )
    (with-read pools pool
      { 'token:= token:module{fungible-v2}
      , 'account:= pool-account
      , 'bonded:= bonded
      , 'lockup:= lockup
      , 'bond:= bond-amount
      , 'active:= active }
      (let*
        ( (date (chain-time))
          (bond (format "{}:{}" [account (format-time "%F" date)]))
        )
        (token::transfer account pool-account bond-amount)
        (insert bonds bond
          { 'pool: pool
          , 'guard: guard
          , 'balance: bond-amount
          , 'date: date
          , 'lockup: lockup
          , 'activity: 0
          })
        (update pools pool
          { 'bonded: (+ bonded bond-amount)
          , 'active: (+ active [bond])
          })
        bond))
  )


  (defun diff-days:integer (a:time b:time)
    (/ (floor (diff-time a b)) DAY))

  (defun withdraw
    ( bond:string
      account:string
    )
    (with-capability (WITHDRAW bond)
      (with-read bonds bond
        { 'pool:= pool
        , 'guard:= guard
        , 'date:= date
        , 'lockup:= lockup
        , 'balance:= balance
        , 'activity:= activity
        }
        (with-read pools pool
          { 'token:= token:module{fungible-v2}
          , 'account:= pool-account
          , 'bonded:= bonded
          , 'service:= service
          , 'active:= active
          , 'activity:= min-activity
          , 'rate:= rate
          }
          (let* ( (elapsed (diff-days (chain-time) date))
                  (servicing (if (< activity min-activity) 0.0
                                 (* balance (* rate elapsed))))
                  (total (+ balance servicing))
                )
            (enforce (> elapsed lockup) "Lockup in force")
            (install-capability (token::TRANSFER pool-account account total))
            (token::transfer pool-account account total)
            (update pools pool
              { 'bonded: (- bonded balance)
              , 'service: (- service servicing)
              , 'active: (- active [bond])
              })))))
  )

  (defun pay-fee
    ( bond:string )
    (with-read bonds bond
      { 'pool:= pool
      , 'balance:= balance
      , 'activity:= activity
      }
      (with-read pools pool
        { 'token:= token:module{fungible-v2}
        , 'bonded:= bonded
        , 'service:= service
        , 'guard:= guard
        , 'fee:=amount
        }
        (enforce-guard guard)
        (update bonds bond
          { 'balance: (+ balance amount)
          , 'activity: (+ activity 1)
          })
        (update pools pool
          { 'bonded: (+ bonded amount)
          , 'service: (- service amount)
          })))
  )

  (defun pick-active (pool:string endorse:bool)
    "Pick a random selection of COUNT bonders from POOL using tx hash as seed"
    (with-read pools pool
      { 'active:=active, 'endorsers:= endorsers, 'denouncers:= denouncers }
      (let ((count (if endorse endorsers denouncers)))
        (enforce
          (>= (length active) count)
          "Not enough active bonders")
        (at 'picks
          (fold (pick)
            { 'hash: (tx-hash)
            , 'cands: active
            , 'picks: []
            }
            (make-list count 0)))))
  )


  (defschema picks
    "Structure for holding random picks"
    hash:string
    cands:[string]
    picks:[integer])

  (defun pick:object{picks} (p:object{picks} x_)
    " Accumulator to pick a random candidate using hash value, \
    \ and re-hash hash value."
    (let* ((h0 (at 'hash p))
           (cs (at 'cands p))
           (count (length cs))
           (p (mod (str-to-int 64 h0) count)))
      { 'hash: (hash h0)
      , 'cands: (+ (take p cs)
                   (take (- (+ p 1) count) cs))
      , 'picks: (+ [(at p cs)] (at 'picks p)) }))



)

(if (read-msg 'upgrade)
  ["upgrade"]
  [ (create-table pools)
    (create-table bonds)
  ]
)
