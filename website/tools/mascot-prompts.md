# Homepage mascot poses

## Hero presenting cutout

Built-in image_gen; source swallowtail-helper.png, output website/public/brand/swallowtail-presenting.png. Terminal is rendered separately with the existing Astro Terminal component.

Create a transparent PNG cutout of ONLY the butler mascot in the supplied image. Preserve his exact standing presenting pose: facing viewer, left side of image arm extended with white gloved palm up presenting something to his left, other arm resting at side. Preserve face, hairstyle, proportions, tuxedo, mulberry bow tie and white collar. Entire body and shoes visible. Remove terminal entirely; terminal will be real HTML behind him. Center full character on portrait 1024x1536 canvas with small margins. Matte solid near-black hair and suit, no highlight streaks or glossy shoes. Clean simple outlines. No terminal, no text, no floor, no shadow, no glow. Genuine RGBA alpha transparency outside figure, NOT checkerboard or solid background.

## Sitting pose matte correction

Final transparency pass prompt: Remove the entire white and gray checkerboard background and make those pixels truly transparent. Preserve the matte mascot, white gloves and shirt, pose, proportions and 1024x1536 canvas. Output RGBA PNG with real alpha, no other changes. Verified RGBA with transparent pixels.

Built-in image_gen edit; sitting PNG is the edit target, peeking PNG the style reference. Replaces website/public/brand/swallowtail-sitting.png.

Edit the FIRST image, the sitting butler mascot. The SECOND image is only the target flat-color style reference. Remove all glossy highlights and shiny streaks on the sitting mascot's hair, shoes, trousers, and jacket. Hair should be a single near-black flat silhouette like the second image, with no gray highlight ribbons or internal shine. Shoes and clothing matte near-black; retain only thin subtle construction outlines needed for lapels and limbs. Preserve EXACT original sitting pose, silhouette, face, white gloves, mulberry bow tie, placement, proportions, 1024x1536 canvas, and transparent background. Do not move hands, seat or feet because the image is aligned to a website divider. No glow, no cast shadow, no new objects, no backdrop. Deliver transparent PNG.

Generated with the built-in image_gen tool on 2026-09-06.
Reference: website/public/brand/swallowtail-helper.png.
Original hero asset retained. PNG alpha preserved.

## website/public/brand/swallowtail-sitting.png

Create a single transparent-background website mascot asset using the supplied image as character/style reference, NOT as a layout to reproduce. Same friendly chibi butler: black side-swept hair, peach face, round black dot eyes, tiny smiling mouth, black tuxedo with white collar, mulberry bow tie, white gloves. Pose: sitting on an invisible horizontal ledge, torso upright, hands resting beside hips on the ledge, short legs dangling over the front. Full character, front view, charming restrained editorial illustration, clean dark outlines, flat colors with subtle shading, very legible at 150px tall. Seat and palms at approximately 70 percent of image height so a real CSS divider can pass beneath them. Center figure tightly framed with small transparent margins. No drawn ledge, no terminal, no text, no scenery, no glow, no drop shadow, no background. True alpha transparency. Preserve character identity.

## website/public/brand/swallowtail-peeking.png

Create one transparent website decorative mascot asset. Reference supplied only for exact character identity and illustration style. Same cute chibi butler, black side-swept hair, peach round face, black dot eyes, small smile, black tuxedo, white collar and gloves, mulberry bow tie. Pose: peeking over an invisible horizontal edge, head and shoulders visible above, both white gloved hands curl over the edge at the bottom, looking at viewer with friendly curiosity. Symmetrical front view. Tight framing small transparent margins. No actual ledge, no terminal, no text, no glow, no scenery, no background, no shadow. True alpha transparency. Clean dark outlines and simple restrained flat colors readable at 120px wide. Only head shoulders and hands; no lower body.
