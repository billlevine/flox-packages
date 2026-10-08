# NEF dependency-shape test packages

Synthetic, deterministic packages for exercising a package catalog: publish
nodes, resolve consumers, and inspect the versions recorded when they were built.
This directory has its own Flox environment, initialized with `flox init`.
All 30 packages are `runCommand` expressions under `.flox/pkgs/`; eight are leaves
and 22 consume custom packages. No packages are published by this project itself.

Run commands below from this directory. Every expression has one
`version = "1";` assignment. Bump that assignment to advance a node.
Leaves write `share/value`; consumers write `share/deps-values`, beginning with
their own name and version and embedding each direct dependency's complete tree
with two extra spaces of indentation. Each package installs a binary with its
package name to print the recorded file. These files are captured at build time.
The mixed consumer also records nixpkgs `hello`'s version and greeting.

Arrows below point from a consumer to its dependency.

## Chain

```text
chain-app -> chain-mid -> chain-leaf
```

Packages: `chain-leaf`, `chain-mid`, `chain-app`.
Tests a simple transitive dependency and how updates propagate through an
intermediate to an application.

## Diamond

```text
           diamond-app
            /       \
   diamond-left     diamond-right
            \       /
           diamond-leaf
```

Packages: `diamond-leaf`, `diamond-left`, `diamond-right`, `diamond-app`.
Tests one shared dependency reached by two paths. A staggered update advances
the leaf and only one branch; the application output exposes the leaf version
recorded on each branch. The shared leaf appears twice in the output.

## Double diamond

```text
           double-app
            /     \
       double-a   double-b
            \     /
           double-mid
            /     \
       double-c   double-d
            \     /
           double-leaf
```

Packages: `double-leaf`, `double-c`, `double-d`, `double-mid`, `double-a`,
`double-b`, `double-app`.
Tests stacked shared dependencies, changes at different depths, and repeated
subtrees: the application records four paths to the leaf.

## Fan-out and fan-in

```text
             fan-app
           /    |    \
       fan-a  fan-b  fan-c
           \    |    /
             fan-leaf
```

Packages: `fan-leaf`, `fan-a`, `fan-b`, `fan-c`, `fan-app`.
Tests three consumers of one leaf and an application combining all three;
use it to compare independently advanced branches.

## Deep chain

```text
deep-6 -> deep-5 -> deep-4 -> deep-3 -> deep-2 -> deep-1
```

Packages: `deep-1`, `deep-2`, `deep-3`, `deep-4`, `deep-5`, `deep-6`.
Tests six levels of transitive resolution, depth-sensitive update propagation,
and preservation of the entire nested version history.

## Two independent leaves

```text
       pair-app
       /      \
   pair-x    pair-y
```

Packages: `pair-x`, `pair-y`, `pair-app`.
Tests independent inputs: advance one leaf and check that the other input stays
at its previous version. It also provides the starting point for changing an
intermediate's dependency set.

## Mixed custom and nixpkgs inputs

```text
       mixed-app
       /       \
  mixed-leaf   hello (nixpkgs)
```

Packages: `mixed-leaf`, `mixed-app`; `hello` is an existing nixpkgs package.
Tests a custom-catalog input and a base nixpkgs input in the same expression.
The application records `hello v<version>` and runs that exact `hello` binary
during its build. The selected nixpkgs revision determines `hello`'s version.

## Catalog references and retargeting

Consumers request `catalogs` and use literal references such as
`catalogs.billlevine.chain-leaf`. This selects a published catalog package;
it does not substitute the neighboring expression from this project.
Keep references literal so Flox can discover them directly.

To retarget every consumer to another catalog, replace `your-handle` here:

```sh
sed -i 's/catalogs\.billlevine\./catalogs.your-handle./g' .flox/pkgs/*/default.nix
```

This one-line command uses GNU `sed`; on macOS use `sed -i ''` instead.
Set the publish destination to the same catalog name.
Without a project `.flox/catalog.lock`, Flox resolves catalog references afresh
for a build. If you add a catalog lock, refresh it with
`flox build update-catalogs` after publishing updates and before rebuilding
consumers. Record the lock state when comparing resolution results.

## Publish order

Publish bottom-up, leaves first. The following sequence covers all packages;
each row is ordered so its dependencies are already published:

| Shape | Publication order |
| --- | --- |
| Chain | `chain-leaf chain-mid chain-app` |
| Diamond | `diamond-leaf diamond-left diamond-right diamond-app` |
| Double diamond | `double-leaf double-c double-d double-mid double-a double-b double-app` |
| Fan-out/fan-in | `fan-leaf fan-a fan-b fan-c fan-app` |
| Deep chain | `deep-1 deep-2 deep-3 deep-4 deep-5 deep-6` |
| Two leaves | `pair-x pair-y pair-app` |
| Mixed inputs | `mixed-leaf mixed-app` |

For each package, use `flox publish -o <catalog> <package>`, for example:

```sh
flox publish -o billlevine chain-leaf
flox publish -o billlevine chain-mid
flox publish -o billlevine chain-app
```

Commit expression changes before publishing so each version has a source
revision. Some newer Flox versions may allow publishing a consumer before its
intermediates, if your flox supports it.

## Reading a result

After the dependencies have been published:

```sh
flox build diamond-app
./result-diamond-app/bin/diamond-app
```

The initial output is:

```text
diamond-app v1
  diamond-left v1
    diamond-leaf v1
  diamond-right v1
    diamond-leaf v1
```

An installed package exposes the same output by running `diamond-app`.
Repeated nodes are intentional: they identify each path through the graph.
Generated `result*` symlinks are ignored by this directory's `.gitignore`.

## Scenario recipes

### Advance a leaf without changing its consumers

1. Publish the initial chain in the order above and build `chain-app`.
2. Change only `.flox/pkgs/chain-leaf/default.nix`'s version to `"2"`, commit, and run
   `flox publish -o billlevine chain-leaf`.
3. Run the existing `./result-chain-app/bin/chain-app`. Its captured output still
   shows `chain-leaf v1`; publishing does not rewrite existing build outputs.
4. Rebuild with `flox build chain-app` and compare. This probes catalog
   resolution for unchanged published intermediates. The recorded tree shows
   whether their published source and transitive pins preserve the old leaf.
   Refresh any project catalog lock first if the intent is to resolve updates.

### Change an intermediate's dependency set across versions

1. Publish both `pair-x` and `pair-y`, then publish `pair-app` v1. Also publish
   `chain-leaf`, `chain-mid`, and `chain-app` v1.
2. In `.flox/pkgs/chain-mid/default.nix`, replace the dependency list entry
   `catalogs.billlevine.chain-leaf` with two entries:
   `catalogs.billlevine.pair-x` and `catalogs.billlevine.pair-y`.
3. Set `chain-mid`'s version to `"2"`, commit, and publish `chain-mid`.
4. Refresh a project catalog lock if present, then build `chain-app`. Its output
   reveals whether the updated intermediate was selected and which independent
   leaf versions the new dependency set resolved. For an explicit new app
   publication, bump `chain-app` to `"2"`, commit, and publish it too.

### Staggered diamond

1. Publish the initial diamond and build `diamond-app`; both paths show v1.
2. Bump `diamond-leaf` to `"2"`, commit, and publish only that leaf.
3. Bump `diamond-left` to `"2"`, commit, and republish only that branch
   (`flox publish -o billlevine diamond-left`). Leave `diamond-right` unchanged.
   Refresh a project catalog lock before publishing the branch if present.
4. Refresh a project catalog lock if present, then run `flox build diamond-app`
   and `./result-diamond-app/bin/diamond-app`.
5. Read each path independently. If published intermediates retain their
   transitive pins, the left path shows leaf v2 and the right path leaf v1.
   If both paths advance, the output instead identifies resolution that
   re-evaluated the old right branch against the new leaf. Record the actual
   behavior, including the lock state.

### Several expressions in one project, one build

All expressions share this environment. Before any publication, build multiple
independent leaves with one invocation:

```sh
flox build chain-leaf diamond-leaf pair-x pair-y
```

After publishing the needed intermediates, build several consumers together:

```sh
flox build chain-app diamond-app fan-app
./result-chain-app/bin/chain-app
./result-diamond-app/bin/diamond-app
./result-fan-app/bin/fan-app
```

With dependencies published for every shape, bare `flox build` builds the entire
project. Consumer builds need their catalog dependencies to exist first.

## Seed and explore

Requires Bash 4+, coreutils (including `tsort`), GNU/BSD `sed`, git, and Flox.
Both tools discover literal catalog references in `default.nix`, check unknown
packages and cycles, and print each Flox command before running it. Set `CATALOG`
(default `billlevine`) to match the expressions; retarget them as described above.

```sh
./seed.sh --dry-run
./seed.sh --catalog billlevine --no-install diamond-app
./seed.sh
```

`seed.sh` builds and publishes in computed dependency order. Optional package
arguments include their dependencies; otherwise it visits all packages.
`--no-install` skips the final integration checks. Otherwise each top package
(no selected consumer depends on it) is installed into a fresh environment and
run using `flox activate -- <package>` to print its recorded tree.
`--run-dir DIR` or `RUN_DIR` selects a new capture directory; the default is
`seed-runs/<UTC timestamp>-seed-<pid>/`. `--dry-run` writes nothing and executes no
Flox commands. `--help` lists defaults and options.

The run directory contains:

- `run.tsv`: UTC start, CLI version, git HEAD, dirty state, catalog, planned order.
- `summary.tsv`: package, step, exit code, elapsed seconds, log path per command.
- `NN-<package>.<step>.log`: update-catalogs (consumers), build, and publish output.
- `NN-<package>.catalog.lock`: the project lock resolved just before each consumer,
  when `update-catalogs` could resolve every reference at that point (see below).
- `final.catalog.lock`: the project lock resolved after everything was published.
- `initial.*` and `<package>.<step>.*`: project manifest, manifest lock, and
  environment metadata snapshots, including those available after a failed step.
- `install-<package>.*`: init/install logs, `.out` with the printed tree,
  `.manifest.lock` with installed versions, and a retained temporary environment.
- `original.catalog.lock`, if present: the lock found before the run.

The run starts without a project catalog lock. Before each consumer it tries
`flox build update-catalogs` and keeps the resulting lock as a record. That
command resolves **all** project references, so on a fresh catalog it fails until
every referenced package exists. Its failure is logged in `summary.tsv` and does
not stop the run, and the generated lock is removed before building, so each
build stays lockless and resolves only its own references. After the last
publish, one more `update-catalogs` records `final.catalog.lock`.
The first failing build or publish stops the run with
`FAILED: <package> at <step> (see <log>)`.
An exit trap restores the original lock, or removes generated locks when none
existed, on success, failure, or an ordinary interrupt. Captures and generated
catalog locks are git-ignored; review local artifacts before sharing them.

Flox publishing also
requires clean committed source available at the git remote. The tools do not
commit or push source changes. Existing build outputs and the Nix store cache
remain available; freshness here means fresh catalog resolution and installation.

`nef` shares the scan and capture code with `seed.sh`:

| Command | Action |
| --- | --- |
| `list` | Package versions and direct catalog dependencies |
| `graph [package]` | Dependency trees, defaulting to all top packages |
| `bump package [version]` | Change only the version assignment; omit version to increment an integer |
| `publish package` | Refresh/capture inputs, build, publish only this package, restore lock |
| `try package [version]` | Install `CATALOG/package[@version]`, print its tree and retained environment path |
| `show package` | Show published versions |
| `cycle package [version]` | Bump, publish, then try the new version |
| `help` | Usage and defaults |

`publish`, `try`, and `cycle` each create a new directory under `seed-runs/`, or
use `RUN_DIR`. `@version` is Flox's supported version requirement syntax.
`cycle` leaves its edit in place if publishing rejects dirty source; commit and
make the revision available at the remote yourself, then use `publish` and `try`.

Inspect the graph and published versions:

```sh
./nef list
./nef graph diamond-app
./nef show diamond-leaf
```

Make a staggered diamond (commit and make each changed revision available at
the remote before its publish command):

```sh
./nef bump diamond-leaf
# Commit the leaf change and make its revision available at the remote.
./nef publish diamond-leaf
./nef bump diamond-left
# Commit the branch change and make its revision available at the remote.
./nef publish diamond-left
./nef try diamond-app
```

Inspect a particular published version in an environment you can keep or remove:

```sh
RUN_DIR=seed-runs/inspect-leaf ./nef try diamond-leaf 2
```
