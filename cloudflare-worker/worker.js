// Cloudflare Worker — proxies all Garmin API requests (OAuth + data endpoints)

export default {
  async fetch(request) {
    const url = new URL(request.url);

    // Debug endpoint to verify worker is live
    if (url.pathname === "/ping") {
      return new Response("pong", { status: 200 });
    }

    // Reject root and unknown paths
    if (url.pathname === "/" || url.pathname === "") {
      return new Response("Garmin API proxy. Use a valid Garmin API path.", { status: 200 });
    }

    const garminUrl = `https://connectapi.garmin.com${url.pathname}${url.search}`;

    // Clone the incoming request and retarget it to Garmin
    const modifiedRequest = new Request(garminUrl, {
      method: request.method,
      headers: request.headers,
      body: request.body,
      redirect: "follow",
    });

    // Override the Host header to match Garmin's domain
    modifiedRequest.headers.set("Host", "connectapi.garmin.com");

    try {
      const resp = await fetch(modifiedRequest);
      // Return Garmin's response as-is
      return new Response(resp.body, {
        status: resp.status,
        statusText: resp.statusText,
        headers: resp.headers,
      });
    } catch (err) {
      return new Response(`Proxy error: ${err.message}`, { status: 502 });
    }
  },
};
