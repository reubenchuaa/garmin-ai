// Cloudflare Worker — proxies Garmin OAuth exchange requests
// Deploy: npx wrangler deploy
// This avoids Garmin's 429 blocking of GitHub Actions cloud IPs

export default {
  async fetch(request) {
    const url = new URL(request.url);

    // Only proxy requests to /oauth-service/
    if (!url.pathname.startsWith("/oauth-service/")) {
      return new Response("Not found", { status: 404 });
    }

    // Forward to Garmin
    const garminUrl = `https://connectapi.garmin.com${url.pathname}${url.search}`;

    const headers = new Headers(request.headers);
    headers.delete("host");

    const resp = await fetch(garminUrl, {
      method: request.method,
      headers: headers,
      body: request.method !== "GET" ? await request.text() : undefined,
    });

    return new Response(resp.body, {
      status: resp.status,
      headers: resp.headers,
    });
  },
};
