import { NextRequest, NextResponse } from "next/server";

// Only the private operator market route is affected; no public navigation link is added.
// Production defaults to 404. When explicitly enabled, require a server-side password.
// HTTPS Basic authentication is sufficient for this read-only operator preview, not a
// replacement for a full access-control system if the page becomes public.
export function middleware(request: NextRequest) {
  if (process.env.NODE_ENV === "development") return NextResponse.next();
  if (process.env.MARKET_COMPARE_ENABLED !== "true") return new NextResponse(null, { status: 404 });
  const password = process.env.MARKET_COMPARE_PASSWORD;
  if (!password || password.length < 20) return new NextResponse(null, { status: 404 });
  const expected = "Basic " + btoa("cc:" + password);
  if (request.headers.get("authorization") !== expected) {
    return new NextResponse("operator access only", {
      status: 401,
      headers: {
        "WWW-Authenticate": 'Basic realm="CC private market"',
        "Cache-Control": "no-store",
      },
    });
  }
  return NextResponse.next();
}

export const config = { matcher: ["/market-compare/:path*"] };
