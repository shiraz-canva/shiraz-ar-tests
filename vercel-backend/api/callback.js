// Canva Connect API — OAuth callback handler
// Deployed on Vercel. Receives the auth code from Canva, exchanges it
// for an access token server-side (required by Canva's confidential client policy),
// then deep-links back into the iOS app with the token.

export default async function handler(req, res) {
  const { code, error, state } = req.query;

  // Handle user-denied or Canva error
  if (error) {
    return res.redirect(`canvaar://oauth/callback?error=${encodeURIComponent(error)}`);
  }

  if (!code) {
    return res.status(400).send("Missing authorization code.");
  }

  const clientID     = process.env.CANVA_CLIENT_ID;
  const clientSecret = process.env.CANVA_CLIENT_SECRET;
  const redirectURI  = process.env.CANVA_REDIRECT_URI; // This function's own URL

  try {
    // Exchange authorization code for access token (must be server-side)
    const tokenRes = await fetch("https://api.canva.com/rest/v1/oauth/token", {
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
        // Canva requires Basic Auth with client credentials
        "Authorization": "Basic " + Buffer.from(`${clientID}:${clientSecret}`).toString("base64"),
      },
      body: new URLSearchParams({
        grant_type:   "authorization_code",
        code:         code,
        redirect_uri: redirectURI,
        // Note: code_verifier is stored in the iOS app's session via the state param.
        // The iOS app passes it encoded in the state; we extract it here.
        code_verifier: decodeStateVerifier(state),
      }).toString(),
    });

    const data = await tokenRes.json();

    if (!tokenRes.ok || !data.access_token) {
      console.error("Token exchange failed:", data);
      return res.redirect(`canvaar://oauth/callback?error=${encodeURIComponent(data.error || "token_exchange_failed")}`);
    }

    // Send the access token back to the iOS app via deep link
    const params = new URLSearchParams({
      access_token:  data.access_token,
      token_type:    data.token_type || "bearer",
      expires_in:    String(data.expires_in || ""),
      refresh_token: data.refresh_token || "",
    });

    return res.redirect(`canvaar://oauth/callback?${params.toString()}`);

  } catch (err) {
    console.error("Callback error:", err);
    return res.redirect(`canvaar://oauth/callback?error=server_error`);
  }
}

// The iOS app encodes the PKCE code_verifier into the state parameter
// so the backend can use it during token exchange.
// Format: base64url(JSON.stringify({ nonce, verifier }))
function decodeStateVerifier(state) {
  try {
    const decoded = Buffer.from(state, "base64url").toString("utf8");
    const parsed  = JSON.parse(decoded);
    return parsed.verifier || "";
  } catch {
    return "";
  }
}
