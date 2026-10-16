import { ogContentType, ogImage, ogSize } from "@/lib/og";
import { getToken } from "@/lib/meta";

export const alt = "credit";
export const size = ogSize;
export const contentType = ogContentType;

export default async function Image({ params }: { params: { id: string } }) {
  const id = Number(params.id);
  const t = Number.isInteger(id) && id >= 0 ? await getToken("credit", id, true) : null;
  return ogImage({
    title: `credit #${params.id}`,
    line: t?.rating ? `rating ${t.rating}` : "a Credit of the Credit Cycle.",
    stat: t?.state,
    art: t?.art,
  });
}
