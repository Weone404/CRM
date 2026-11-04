import { lazy, Suspense } from 'react';

// Dark sky with the live globe, behind the employee and student sign-in cards.
const Globe3D = lazy(() => import('./Globe3D'));

export default function AuthBackdrop({ children }) {
  return (
    <div className="relative min-h-screen overflow-hidden flex items-center justify-center p-4"
      style={{ background: 'radial-gradient(110% 80% at 50% 25%, #0b2540 0%, #050b16 55%, #02060d 100%)' }}>
      <div className="pointer-events-none absolute inset-0 flex items-center justify-center opacity-50">
        <div className="w-[130vw] h-[130vw] max-w-[820px] max-h-[820px] sm:w-[95vw] sm:h-[95vw]">
          <Suspense fallback={null}><Globe3D ambient /></Suspense>
        </div>
      </div>
      <div className="relative w-full flex justify-center">{children}</div>
    </div>
  );
}
