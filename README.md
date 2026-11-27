# origaitv-pkgs

The packages your [OrigaiTV](https://github.com/radomird/origaitv-os) box installs and updates from. OrigaiTV is the world's first open-source agentic TV OS. Powered by [Omarchy](https://omarchy.org).

There's nothing to download here by hand. The USB stick puts the packages on a new box, and after that your box keeps itself up to date from here.

## What's in it

Your box keeps Omarchy's own `omarchy` package exactly as Omarchy ships it. OrigaiTV adds two packages next to it:

- **`origaitv`** is everything OrigaiTV adds on top of Omarchy: the TV's home, setup, the phone remote and the `origaitv` command. None of it goes into `/usr/share/omarchy/`, which is Omarchy's.
- **`origaitv-keyring`** holds the public key the packages are signed with.

That way one update brings Arch, Omarchy and OrigaiTV along together, and your box takes a snapshot first so you can go back. On the TV it's _Settings > System > Updates_. In a terminal it's `origaitv update`, which runs `omarchy update` underneath.

## Stable and edge

CI builds the packages from [origaitv-os](https://github.com/radomird/origaitv-os), signs them, and publishes a pacman repository here as a release, one for each channel:

- **stable** has OrigaiTV's releases. A box installed from a release's ISO starts on it.
- **edge** has every origaitv-os commit that passes its checks. It's for trying what's next. A box installed from a release candidate's ISO, or from edge's, starts on it.

A release candidate has no packages of its own. Its ISO carries edge's, from the commit it was cut on. Edge's builds count from the last release or candidate: `1.0.0rc6.r12.gabc1234` is twelve commits after 1.0.0-rc6, and `1.0.0.r3.gabc1234` three after 1.0.0. Only a release on stable has a bare version, like `1.0.0`.

To try edge, run `origaitv channel edge` and then `origaitv update`. `origaitv channel stable` takes you back, and your box picks up releases again from the next one.

## Something went wrong?

If an update didn't go right, [tell me what happened](https://github.com/radomird/origaitv-pkgs/issues/new/choose). For a security problem, such as a package that isn't what it says it is, please [tell me privately](https://github.com/radomird/origaitv-pkgs/security/advisories/new) first.

## For developers

- `origaitv/PKGBUILD` and `origaitv-keyring/PKGBUILD` are the recipes.
- Every hour, `.github/workflows/build.yml` looks for a new release tag or a new green commit. It builds in an Arch container, signs, publishes, and then installs from the release with pacman, checking every signature on the way.
- The signing key is a GitHub Actions secret and never leaves CI. Only the job that signs gets it, and that job builds nothing: it takes the built files, checks them and runs `bin/sign`. Its public half is `origaitv-keyring/origaitv.gpg`.
- A pull request's test run never gets that key. It signs its packages with a throwaway key made for the run (`bin/test-key`), which only the run's own test box trusts.
- Once a version is published, its file never changes, so your box never sees two different files with the same version.

## License

MIT, like Omarchy. The `origaitv` package also carries OrigaiTV's menu sounds and setup music, which are all rights reserved, and fonts under the SIL Open Font License. Each keeps its licence file in the package. OrigaiTV isn't made or endorsed by the Omarchy project.
