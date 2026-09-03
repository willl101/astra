/** Package-owned invariant companion for the proactive screen observer. */

import type { Context } from '@deepseek-ai/cordis'
import type { InvariantInstaller } from '@deepseek-ai/dsh-invariants'

const PACKAGE_NAME = '@deepseek-ai/dsh-experimental-proactive-screen'

export const name = 'experimental-proactive-screen-invariant'
export const inject = ['invariants']

// No runtime invariant: the plugin retains only process-local suppression state
// and delegates model and process correctness to their owning services.
const install: InvariantInstaller = () => {}

/** Register this package's invariant ownership. */
export const apply = (ctx: Context): Promise<() => void> =>
  Promise.resolve(ctx.invariants.register(PACKAGE_NAME, install))
