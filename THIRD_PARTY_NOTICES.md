# Third-Party Software Notices

Cadenza uses the third-party Swift packages listed below. The versions and
revisions are taken from
`Cadenza.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
The corresponding license and notice texts are reproduced from those exact
checked-out revisions in `Cadenza/Resources/ThirdPartyLicenses/`; line endings
and trailing whitespace may be normalized. They are also included in the
application resources generated from `project.yml`.

This document covers third-party components only. It does not grant a license
for Cadenza itself.

## Resolved package graph

| Package | Source | Resolved version or revision | License | Bundled files |
| --- | --- | --- | --- | --- |
| KeychainAccess | <https://github.com/kishikawakatsumi/KeychainAccess> | 4.2.2 (`84e546727d66f1adc5439debad16270d0fdd04e7`) | MIT | `KeychainAccess-LICENSE.txt` |
| WhisperKit, including SpeakerKit | <https://github.com/shuiandy/WhisperKit> | `969a385e1ae9731bd052b4a6334c58a6c54edeab` | MIT | `WhisperKit-LICENSE.txt` |
| swift-argument-parser | <https://github.com/apple/swift-argument-parser> | 1.7.1 (`626b5b7b2f45e1b0b1c6f4a309296d1d21d7311b`) | Apache-2.0 with Runtime Library Exception | `swift-argument-parser-LICENSE.txt` |
| swift-asn1 | <https://github.com/apple/swift-asn1> | 1.6.0 (`9f542610331815e29cc3821d3b6f488db8715517`) | Apache-2.0 | `swift-asn1-LICENSE.txt`, `swift-asn1-NOTICE.txt` |
| swift-collections | <https://github.com/apple/swift-collections> | 1.4.1 (`6675bc0ff86e61436e615df6fc5174e043e57924`) | Apache-2.0 with Runtime Library Exception | `swift-collections-LICENSE.txt` |
| swift-crypto | <https://github.com/apple/swift-crypto> | 4.3.0 (`fa308c07a6fa04a727212d793e761460e41049c3`) | Apache-2.0 | `swift-crypto-LICENSE.txt`, `swift-crypto-NOTICE.txt` |
| swift-jinja | <https://github.com/huggingface/swift-jinja> | 2.3.2 (`f731f03bf746481d4fda07f817c3774390c4d5b9`) | Apache-2.0 | `swift-jinja-LICENSE.txt` |
| swift-transformers | <https://github.com/huggingface/swift-transformers> | 1.1.9 (`150169bfba0889c229a2ce7494cf8949f18e6906`) | Apache-2.0 | `swift-transformers-LICENSE.txt` |
| yyjson | <https://github.com/ibireme/yyjson> | 0.12.0 (`8b4a38dc994a110abaec8a400615567bd996105f`) | MIT | `yyjson-LICENSE.txt` |

Some packages in the resolved graph may support products that Cadenza does not
link directly. They are included here conservatively so the notice remains
complete for the resolved build graph.

## Third-party icon assets

The Claude, MiniMax, OpenAI, and Notion provider icons under
`Cadenza/Resources/Assets.xcassets/` use SVG path data from
[Lobe Icons](https://github.com/lobehub/lobe-icons) (verified against revision
`f07e9be35aef452ce735f95ea8204a14ecc513f7`), licensed under the MIT License.
The corresponding license is included as `LobeIcons-LICENSE.txt`.
Some copies adjust only presentation attributes such as color, size, or an SVG
gradient identifier.

Provider names and logos may also be trademarks of their respective owners.
Their presence identifies an optional integration and does not imply sponsorship
or endorsement.

## Runtime-downloaded model files

Cadenza does not store model weights in this repository. When a user chooses
the relevant local features, WhisperKit can download model files from
`argmaxinc/whisperkit-coreml`, and SpeakerKit can download model files from
`argmaxinc/speakerkit-coreml` on Hugging Face. Those model files are separate
artifacts with their own model-card terms and are not covered by the Swift
package licenses above.

Before bundling, mirroring, or redistributing any model weights with a Cadenza
release, review the exact model revision and preserve all license and attribution
requirements that accompany it.

## Updating this notice

Whenever `Package.resolved` changes:

1. verify every resolved package's license at the resolved revision;
2. refresh the matching files under `Cadenza/Resources/ThirdPartyLicenses/`;
3. preserve package `NOTICE` files and license exceptions; and
4. confirm the built application contains the refreshed resources.
