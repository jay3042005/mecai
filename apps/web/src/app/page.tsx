/**
 * Landing Page (docs/design.md §5.2).
 *
 * Dedicated overview screen introducing the MEC-AI platform.
 * Clinicians/guardians click "Get Started" to navigate to the Clinical Console at /dashboard.
 */

import { IntroHero } from "@/components/intro-hero";

export default function HomePage() {
  return <IntroHero />;
}
