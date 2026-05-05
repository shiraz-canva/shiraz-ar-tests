export default async function handler(req, res) {
  const { code, error, state } = req.query;

  if (error) {
    const desc = req.query.error_description || "";
    console.error("Canva auth error:", error, desc);
    return res.redirect(
      `canvaar://oauth/callback?error=${encodeURIComponent(error)}&error_description=${encodeURIComponent(desc)}`
    );
  }
  if (!code) {
    return res.status(400).send("Missing authorization code.");
  }

  const clientID     = process.env.CANVA_CLIENT_ID;
  const clientSecret = process.env.CANVA_CLIENT_SECRET;
  const redirectURI  = process.env.CANVA_REDIRECT_URI;

  try {
    const tokenRes = await fetch("https://api.canva.com/rest/v1/oauth/token", {
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
        "Authorization": "Basic " + Buffer.from(`${clientID}:${clientSecret}`).toString("base64"),
      },
      body: new URLSearchParams({
        grant_type:    "authorization_code",
        code:          code,
        redirect_uri:  redirectURI,
        code_verifier: state || "",
      }).toString(),
    });

    const data = await tokenRes.json();
    if (!tokenRes.ok || !data.access_token) {
      console.error("Token exchange failed:", data);
      return res.redirect(`canvaar://oauth/callback?error=${encodeURIComponent(data.error || "token_exchange_failed")}`);
    }

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
