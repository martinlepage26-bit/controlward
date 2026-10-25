# D1 read token: declared-and-captured proof

This is a declared-and-captured proof, not live policy introspection. Cloudflare's `GET /user/tokens/verify` returns the token id and status only. It does not return the permission list, and reading that list would need another token permission. The runner never probes with a write.

Martin creates the token himself. Nothing in this repo creates or requests a token, and no token value is stored here.

The gitignored file `leadgen.token-policy.json` (template: `leadgen.token-policy.example.json`) holds the token id and its permission list. At startup the live run calls verify and fails closed unless all of these hold, with each saved token checked on its own:

- `LEADGEN_CF_TOKEN_MECOM_READ` grants exactly D1 Read on `e1e9fa25-4c6e-476e-bf16-979c0fd9e5b1` and nothing else
- `LEADGEN_CF_TOKEN_PHAROS_READ` grants exactly D1 Read on `959e5bdb-4213-496a-9557-10ec410440d7` and nothing else
- the id verify returns for that token equals the saved id
- the status is `active`

Anything else (the two accounts swapped, one token covering both accounts while the other has no grants, a write-scoped declaration, a missing declaration, an inactive or unverifiable token, or an id mismatch) refuses the run before a draft or a row. A snapshot SELECT that would be sent with that database's write token, or a read token equal to that database's write token, also stops the run before a draft or a row.

## Permission groups

Account scope `com.cloudflare.api.account`. Names are the Cloudflare token permission groups. Ids are the published permission-group ids for those names.

| Name | Id | Allowed |
| --- | --- | --- |
| D1 Read | `192192df92ee43ac90f2aeeffce67e35` | yes, exactly one grant, on that token's own account |
| D1 Write | `09b2857d1c31407795e75e3fed8617a1` | no |

## Account ids

| Account | Id |
| --- | --- |
| me.com | `e1e9fa25-4c6e-476e-bf16-979c0fd9e5b1` |
| PHAROS | `959e5bdb-4213-496a-9557-10ec410440d7` |

The two read-token env names are `LEADGEN_CF_TOKEN_MECOM_READ` and `LEADGEN_CF_TOKEN_PHAROS_READ`. The policy file names those env vars. It does not contain the token values.
