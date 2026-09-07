// Retained command for updating the addon icon from the approved mascot.
import { copyFileSync } from 'node:fs'
copyFileSync(new URL('../public/brand/swallowtail-butler.png', import.meta.url),
  new URL('../../project/addons/swallowtail/icon.png', import.meta.url))
