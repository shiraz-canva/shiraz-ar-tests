# Canva AR — Vercel Auth Backend

Handles the OAuth token exchange server-side, as required by Canva's Connect API
(confidential clients only — no client-side token exchange allowed).

## Deploy in 3 steps

### 1. Install Vercel CLI
```bash
npm install -g vercel
```

### 2. Deploy
```bash
cd vercel-backend
vercel
```
Follow the prompts — choose a project name like `canva-ar-auth`.
Your URL will be `https://canva-ar-auth.vercel.app` (or similar).

### 3. Set environment variables
In the Vercel dashboard → your project → Settings → Environment Variables, add:

| Variable | Value |
|---|---|
| `CANVA_CLIENT_ID` | your client ID from the Canva developer portal |
| `CANVA_CLIENT_SECRET` | your client secret from the Canva developer portal |
| `CANVA_REDIRECT_URI` | `https://canva-ar-auth.vercel.app/callback` |

Then redeploy: `vercel --prod`

## After deploying

1. **Update Canva portal** — go to your integration's Authentication page and replace
   the current redirect URL with `https://canva-ar-auth.vercel.app/callback`

2. **Update iOS app** — in `CanvaAPIService.swift`, replace `YOUR_VERCEL_APP` with
   your actual Vercel subdomain:
   ```swift
   private let redirectURI = "https://canva-ar-auth.vercel.app/callback"
   ```
