// Cloudflare Worker — proxies Garmin OAuth exchange requests
// Transparently forwards all headers, body, and method

export default {
  async fetch(request) {
    const url = new URL(request.url);

    // Only proxy requests to /oauth-service/
    if (!url.pathname.startsWith("/oauth-service/")) {
      return new Response("Not found", { status: 404 });
    }

    // Build Garmin URL
    const garminUrl = `https://connectapi.garmin.com${url.pathname}${url.search}`;

    // Clone all headers, strip Cloudflare-specific ones
    const headers = new Headers();
    for (const [key, value] of request.headers.entries()) {
      const k = key.toLowerCase();
      if (k === "host" || k.startsWith("cf-") || k === "x-forwarded-for" || k === "x-real-ip") continue;
      headers.set(key, value);
    }
    headers.set("Host", "connectapi.garmin.com");

    const resp = await fetch(garminUrl, {
      method: request.method,
      headers: headers,
      body: request.method !== "GET" && request.method !== "HEAD" ? request.body : undefined,
      redirect: "follow",
    });

    const respHeaders = new Headers(resp.headers);
    respHeaders.set("Access-Control-Allow-Origin", "*");

    return new Response(resp.body, {
      status: resp.status,
      statusText: resp.statusText,
      headers: respHeaders,
    });
  },
};
