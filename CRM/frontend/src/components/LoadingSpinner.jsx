export default function LoadingSpinner({ size = 'md', text = '' }) {
  const sizes = { sm: 'w-4 h-4', md: 'w-8 h-8', lg: 'w-12 h-12' };
  return (
    <div className="flex flex-col items-center justify-center gap-3">
      <div className={`${sizes[size]} border-4 rounded-full animate-spin`} style={{ borderColor: 'rgba(60,60,67,0.22)', borderTopColor: '#5856D6' }}></div>
      {text && <p className="text-glass-secondary text-sm">{text}</p>}
    </div>
  );
}
