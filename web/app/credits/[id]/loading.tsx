import { DetailLoading } from "@/components/DetailLoading";

// Shown at once on navigation while the route's metadata resolves on the server.
export default function Loading() {
  return <DetailLoading kind="credit" />;
}
