import type { Metadata } from "next";
import type { ReactNode } from "react";

export const metadata: Metadata = {
  title: "Pedro Voice Agent",
  description: "An independent Apple Watch voice client for the coding agent on your Mac.",
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <body style={{ background: "#faf9f7", color: "#141413", margin: 0 }}>{children}</body>
    </html>
  );
}
