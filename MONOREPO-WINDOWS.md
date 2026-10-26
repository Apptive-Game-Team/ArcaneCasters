# Windows submodule workspace

The root origin is `Apptive-Game-Team/ArcaneCasters`. Component directories are independent Git submodules listed in `.gitmodules`. `./dev branch` discovers those components.

Restored locally on 2026-10-21 without checking out, deleting, or moving working files. Existing environment files, ignored files, and unfinished edits were retained. The root and component restoration branches are `local/restored-submodules-20261021`. Root baseline: `8f5da0e30`.

The original monorepo branches and all archived histories remain in the root Git store. Changes committed only in the flattened monorepo remain visible as local component changes; their original commits remain reachable from `codex/desktop-full-build-updates`. No user work was committed or pushed during restoration.

Component Git directories are `.git/modules/<name>`. Their object alternates reference the root `.git/objects`; preserve that root Git store and its archived refs. Before moving a component independently, run `git repack -a` in the component and remove its alternates only after verifying the independent object store.

Commit component changes in the component repository and update umbrella gitlinks separately. Do not use checkout/reset/submodule update to overwrite unfinished changes.
