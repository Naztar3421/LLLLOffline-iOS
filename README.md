# LLLLOffline-iOS

## POC-1: in-app localhost

`LocalHTTPPOC.dylib` starts a loopback HTTP server on `127.0.0.1:17891` and self-tests `GET /test`.

## POC-2: one real game API through localhost

The current experiment hooks `NSURLSession` and only redirects:

`/v1/profile/get_info`

when the URL host is either the official API host or the current private-server API host.

Flow:

```
Game
  -> private/official API URL
  -> LocalHTTPPOC hook
  -> http://127.0.0.1:17891/v1/profile/get_info
  -> in-app localhost proxy
  -> https://api-alfa-l4.hasu-link.club/v1/profile/get_info
  -> original game response
```

All other API paths are untouched.

The proxy copies the request method, headers and body, forwards the selected request to the existing private server, then returns the upstream status/body to the game. It also adds the response header `X-LLL-Offline-POC: localhost-proxy`.

A successful end-to-end test should show:

- `LLL LOCALHOST OK` — localhost server works.
- `LLL POC2 REDIRECT` — the selected game request was redirected.
- `LLL POC2 API HIT` — localhost received it and successfully forwarded it to the private server.

This POC does not import or inject account-export data. The account response still comes from the user's current private-server session.