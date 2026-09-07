# Butler callout poses

Generated with built-in image_gen on 2026-09-06 from the character sheet. PNG masters live in `../public/brand/callouts/`; the shared Callout component renders optimized 152px WebP assets at 76px (48px on narrow screens).

| Type | Expression / gesture |
| --- | --- |
| Note | Friendly smile and presenting palm |
| Tip | Happy idea pose with raised finger |
| Important | Attentive expression and raised finger |
| Warning | Concerned expression with hand at cheek |
| Caution | Firm expression with palm held up to stop |

These illustrations support the callout text. They are decorative, not buttons. Keep explicit labels, custom titles, and the existing type colors. Callout body content and page-copy output stay intact. Do not add the homepage trivia behavior to documentation callouts.

## Prompts

### note

Create ONE square transparent PNG mascot illustration for a documentation note callout. Use supplied character sheet strictly as identity/style reference, not as layout. Only a waist-up bust of the same friendly chibi butler with oversized round head, asymmetrical side-swept near-black hair, peach face, black dot eyes, white collar and gloves, near-black tuxedo and mulberry bow tie. Friendly informative expression, small closed smile, one white-gloved open palm presenting to the side. Head and gesture both entirely within canvas, tightly centered with small 5 percent margins, chest ends near bottom. Readable at 80 pixels wide. Flat matte colors, no hair highlights, no shoe/clothing shine, no gradients, no glow, no cast shadows. No text, no symbols, no frame, no props, no background. Real transparent RGBA alpha background, not a painted checkerboard. Exactly one character, not a sheet.

### tip

Create ONE square transparent PNG mascot illustration for a documentation tip callout. Use supplied character sheet strictly as identity/style reference, not as layout. Only a waist-up bust of the same friendly chibi butler with oversized round head, asymmetrical side-swept near-black hair, peach face, black dot eyes, white collar and gloves, near-black tuxedo and mulberry bow tie. Pleased expression with a small open smile, one white-gloved index finger raised beside his face in an I-have-an-idea pose. Head and gesture both entirely within canvas, tightly centered with small 5 percent margins, chest ends near bottom. Readable at 80 pixels wide. Flat matte colors, no hair highlights, no shoe/clothing shine, no gradients, no glow, no cast shadows. No text, no symbols, no frame, no props, no background. Real transparent RGBA alpha background, not a painted checkerboard. Exactly one character, not a sheet.

### important

Create ONE square transparent PNG mascot illustration for a documentation important callout. Use supplied character sheet strictly as identity/style reference, not as layout. Only a waist-up bust of the same friendly chibi butler with oversized round head, asymmetrical side-swept near-black hair, peach face, black dot eyes, white collar and gloves, near-black tuxedo and mulberry bow tie. Attentive serious but kind expression, small neutral mouth, one white-gloved index finger held upright prominently beside his face to emphasize a point. Head and gesture both entirely within canvas, tightly centered with small 5 percent margins, chest ends near bottom. Readable at 80 pixels wide. Flat matte colors, no hair highlights, no shoe/clothing shine, no gradients, no glow, no cast shadows. No text, no symbols, no frame, no props, no background. Real transparent RGBA alpha background, not a painted checkerboard. Exactly one character, not a sheet.

### warning

Create ONE square transparent PNG mascot illustration for a documentation warning callout. Use supplied character sheet strictly as identity/style reference, not as layout. Only a waist-up bust of the same chibi butler with oversized round head, asymmetrical side-swept near-black hair, peach face, black dot eyes, white collar and gloves, near-black tuxedo and mulberry bow tie. Concerned expression, small downturned mouth, white-gloved hand held to cheek, conveying pay attention without panic. Head and gesture entirely within canvas, tightly centered with small 5 percent margins, chest ends near bottom. Readable at 80px wide. Flat matte colors, no highlights, no gradients, no glow, no shadows. No text, symbols, frame, props, background. Real RGBA alpha transparency, no checkerboard. One character, not a sheet.

### caution

Create ONE square transparent PNG mascot illustration for a documentation caution callout. Use supplied character sheet strictly as identity/style reference, not as layout. Only a waist-up bust of the same chibi butler with oversized round head, asymmetrical side-swept near-black hair, peach face, black dot eyes, white collar and gloves, near-black tuxedo and mulberry bow tie. Firm serious expression, small straight mouth, one white-gloved hand raised palm facing the viewer in a clear stop gesture beside his face. Head and gesture entirely within canvas, tightly centered with small 5 percent margins, chest ends near bottom. Readable at 80px wide. Flat matte colors, no highlights, no gradients, no glow, no shadows. No text, symbols, frame, props, background. Real RGBA alpha transparency, no checkerboard. One character, not a sheet.


Background cleanup: the owner authorized local removal of the generated white/checkerboard backgrounds. Run python website/tools/remove-callout-backgrounds.py from the repository root to remove border-connected pale pixels while preserving enclosed white shirts and gloves, and generate the 152px transparent WebP assets. NOTE avatars sit on the right on desktop and phones.

Layout: text sits in a rounded speech bubble with a tail toward the butler outside it. On phones, the butler sits above the full-width bubble. NOTE stays on the right.

Type labels interrupt the bubble's top border; custom titles remain inside. On phones, labels sit opposite the tail to keep both clear.
