# Vendored dependencies

Dependencies are ordinary source files with their upstream licenses, not submodules. No dependency download is needed to build or test. Their original source contents are unmodified.

| Package | Pinned release | Contents retained |
| --- | --- | --- |
| [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/v5.0.2) | `v5.0.2` | Transitive source dependencies of GameEscrow and the test ERC-20, plus MIT license |
| [forge-std](https://github.com/foundry-rs/forge-std/tree/v1.9.7) | `v1.9.7` | Complete `src/` and MIT/Apache licenses |

Downloaded from the respective upstream GitHub release-tag archives. `SHA256SUMS` pins every retained upstream file by content. From the repository root, run `sha256sum --check lib/SHA256SUMS` to check integrity. The checksum file and this provenance note are project additions. Test-only dependencies are not linked into the deployed application.
