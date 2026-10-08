# Third-party notices

## whisper.cpp

VoicePanel links the official `whisper.cpp` XCFramework from `ggml-org/whisper.cpp`.

- pinned release: `v1.7.5`;
- SwiftPM artifact checksum: recorded in `Package.swift`;
- upstream license: MIT;
- upstream project: `https://github.com/ggml-org/whisper.cpp`.

The framework is downloaded by Swift Package Manager during the first build and is not stored in this source archive.

## Whisper model files

Optional GGML model files and compiled Core ML encoder ZIPs are downloaded from
the `ggerganov/whisper.cpp` Hugging Face repository. VoicePanel uses fixed
filenames and pinned SHA-1 or SHA-256 content checks before installation.

Core ML packages accelerate the Whisper encoder and may use Apple Neural Engine
resources selected by Core ML. They do not move the Whisper decoder to ANE. Model
and encoder files are installed into Application Support and are not bundled in
this archive or included in transcript history.

## GigaAM

The supported GigaAM v3 model families originate from `salute-developers/GigaAM`.

- upstream model/code license: MIT;
- upstream project: `https://github.com/salute-developers/GigaAM`;
- supported variants: v3 CTC, v3 RNN-T, v3 E2E CTC and v3 E2E RNN-T.

VoicePanel does not bundle Python, PyTorch or the upstream training/inference package.

## GigaAM sherpa-onnx model packages

VoicePanel downloads pre-converted INT8 ONNX packages from the community repository `Smirnov75/GigaAM-v3-sherpa-onnx` on Hugging Face.

- repository: `https://huggingface.co/Smirnov75/GigaAM-v3-sherpa-onnx`;
- repository license metadata: MIT;
- every expected file and SHA-256 is pinned in `GigaAMModelCatalog.swift`;
- a package is installed only after every file passes verification.

These model files are not stored in this source archive. Users should review the source repository and model license before redistribution.

## SAGE FRED-T5 Russian correction

VoicePanel can download an INT8 ONNX export of `ai-forever/sage-fredt5-distilled-95m` for optional Russian final-text correction with GigaAM.

- original model: `https://huggingface.co/ai-forever/sage-fredt5-distilled-95m`;
- original model license: MIT;
- INT8 ONNX export: `https://huggingface.co/krut42/voice-sage95m-int8`;
- pinned export revision: `3343e7765f2cd668a04e3200f8753b382444f274`;
- encoder and decoder SHA-256 values are pinned in `RussianCorrectionModelCatalog.swift`;
- the package is downloaded into Application Support and is not bundled in this source archive or DMG.

The export contains separate encoder and decoder ONNX graphs and GPT-2 BPE tokenizer files. VoicePanel uses it only for local Russian text correction and does not bundle the upstream PyTorch runtime.

## Qwen3-ASR

VoicePanel can download curated INT8 sherpa-onnx conversions of `Qwen/Qwen3-ASR-0.6B` and `Qwen/Qwen3-ASR-1.7B`.

- original models: `https://huggingface.co/Qwen/Qwen3-ASR-0.6B` and `https://huggingface.co/Qwen/Qwen3-ASR-1.7B`;
- original model license: Apache-2.0;
- 0.6B converted package: `https://huggingface.co/csukuangfj2/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25`;
- 1.7B experimental converted package: `https://huggingface.co/thieunv/sherpa-onnx-qwen3-asr-1.7B-int8`;
- every expected file and minimum size is declared in `LocalONNXModelCatalog.swift`;
- every 0.6B file uses a pinned SHA-256 value;
- every 1.7B file is accepted only when its downloaded content matches the content identity supplied by Hugging Face: SHA-256 for LFS objects or Git blob SHA-1 for regular repository files.

The converted files are downloaded into Application Support and are not bundled in this source archive. The 1.7B conversion is a community export and remains marked experimental in VoicePanel.

## NVIDIA Parakeet TDT 0.6B v3

VoicePanel can download an INT8 sherpa-onnx conversion of NVIDIA's `parakeet-tdt-0.6b-v3` automatic speech recognition model.

- creator: NVIDIA;
- original model: `https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3`;
- original model license: Creative Commons Attribution 4.0 International (`CC-BY-4.0`);
- license text: `https://creativecommons.org/licenses/by/4.0/`;
- converted package: `https://huggingface.co/csukuangfj2/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8`;
- modification: the distributed package is a quantized INT8 ONNX conversion for sherpa-onnx;
- every expected encoder, decoder, joiner, token file, and SHA-256 is pinned in `LocalONNXModelCatalog.swift`.

The converted files are downloaded into Application Support and are not bundled in this source archive. Redistribution must preserve the attribution and license requirements of the original model.

## Silero VAD

VoicePanel can download a Silero voice-activity-detection ONNX model distributed
through the sherpa-onnx release assets.

- upstream project: `https://github.com/snakers4/silero-vad`;
- upstream license: MIT;
- download asset: `https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx`;
- the expected SHA-256 is pinned in `SileroVADModelManager.swift`;
- the model is stored in Application Support and is not bundled in this source
  archive or DMG.

## sherpa-onnx and ONNX Runtime

VoicePanel declares the native sherpa-onnx and ONNX Runtime XCFrameworks as direct SwiftPM binary targets. The asset URLs and checksums come from the `willwade/sherpa-onnx-spm` distribution. Their macOS slices may be statically linked rather than copied into the final app bundle.

- native XCFramework assets: `1.13.2`;
- checksums are pinned to the bytes currently served by the `1.13.2` release URLs and documented on that release page;
- the URLs do not use query-string cache revisions because query parameters do not select different GitHub release assets;
- sherpa-onnx license: Apache-2.0;
- ONNX Runtime license: MIT;
- Swift package repository: `https://github.com/willwade/sherpa-onnx-spm`;
- sherpa-onnx upstream: `https://github.com/k2-fsa/sherpa-onnx`;
- ONNX Runtime upstream: `https://github.com/microsoft/onnxruntime`.

The frameworks are downloaded during the first SwiftPM build and are not stored in this source archive.

### OpenSSL

The non-macOS validation target links the system OpenSSL `libcrypto` implementation for AES-GCM compatibility tests.

- upstream project: `https://www.openssl.org/`;
- license: Apache License 2.0;
- usage: non-macOS development and validation only;
- macOS release builds use Apple CryptoKit and do not compile or bundle this target.

## Bundled runtime license texts

The following license texts accompany the runtimes linked into the macOS app.
Downloaded model packages are separate and retain the terms listed above.

### whisper.cpp (MIT)

```text
MIT License

Copyright (c) 2023-2024 The ggml authors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### sherpa-onnx (Apache-2.0)

```text
Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

   TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

   1. Definitions.

      "License" shall mean the terms and conditions for use, reproduction,
      and distribution as defined by Sections 1 through 9 of this document.

      "Licensor" shall mean the copyright owner or entity authorized by
      the copyright owner that is granting the License.

      "Legal Entity" shall mean the union of the acting entity and all
      other entities that control, are controlled by, or are under common
      control with that entity. For the purposes of this definition,
      "control" means (i) the power, direct or indirect, to cause the
      direction or management of such entity, whether by contract or
      otherwise, or (ii) ownership of fifty percent (50%) or more of the
      outstanding shares, or (iii) beneficial ownership of such entity.

      "You" (or "Your") shall mean an individual or Legal Entity
      exercising permissions granted by this License.

      "Source" form shall mean the preferred form for making modifications,
      including but not limited to software source code, documentation
      source, and configuration files.

      "Object" form shall mean any form resulting from mechanical
      transformation or translation of a Source form, including but
      not limited to compiled object code, generated documentation,
      and conversions to other media types.

      "Work" shall mean the work of authorship, whether in Source or
      Object form, made available under the License, as indicated by a
      copyright notice that is included in or attached to the work
      (an example is provided in the Appendix below).

      "Derivative Works" shall mean any work, whether in Source or Object
      form, that is based on (or derived from) the Work and for which the
      editorial revisions, annotations, elaborations, or other modifications
      represent, as a whole, an original work of authorship. For the purposes
      of this License, Derivative Works shall not include works that remain
      separable from, or merely link (or bind by name) to the interfaces of,
      the Work and Derivative Works thereof.

      "Contribution" shall mean any work of authorship, including
      the original version of the Work and any modifications or additions
      to that Work or Derivative Works thereof, that is intentionally
      submitted to Licensor for inclusion in the Work by the copyright owner
      or by an individual or Legal Entity authorized to submit on behalf of
      the copyright owner. For the purposes of this definition, "submitted"
      means any form of electronic, verbal, or written communication sent
      to the Licensor or its representatives, including but not limited to
      communication on electronic mailing lists, source code control systems,
      and issue tracking systems that are managed by, or on behalf of, the
      Licensor for the purpose of discussing and improving the Work, but
      excluding communication that is conspicuously marked or otherwise
      designated in writing by the copyright owner as "Not a Contribution."

      "Contributor" shall mean Licensor and any individual or Legal Entity
      on behalf of whom a Contribution has been received by Licensor and
      subsequently incorporated within the Work.

   2. Grant of Copyright License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      copyright license to reproduce, prepare Derivative Works of,
      publicly display, publicly perform, sublicense, and distribute the
      Work and such Derivative Works in Source or Object form.

   3. Grant of Patent License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      (except as stated in this section) patent license to make, have made,
      use, offer to sell, sell, import, and otherwise transfer the Work,
      where such license applies only to those patent claims licensable
      by such Contributor that are necessarily infringed by their
      Contribution(s) alone or by combination of their Contribution(s)
      with the Work to which such Contribution(s) was submitted. If You
      institute patent litigation against any entity (including a
      cross-claim or counterclaim in a lawsuit) alleging that the Work
      or a Contribution incorporated within the Work constitutes direct
      or contributory patent infringement, then any patent licenses
      granted to You under this License for that Work shall terminate
      as of the date such litigation is filed.

   4. Redistribution. You may reproduce and distribute copies of the
      Work or Derivative Works thereof in any medium, with or without
      modifications, and in Source or Object form, provided that You
      meet the following conditions:

      (a) You must give any other recipients of the Work or
          Derivative Works a copy of this License; and

      (b) You must cause any modified files to carry prominent notices
          stating that You changed the files; and

      (c) You must retain, in the Source form of any Derivative Works
          that You distribute, all copyright, patent, trademark, and
          attribution notices from the Source form of the Work,
          excluding those notices that do not pertain to any part of
          the Derivative Works; and

      (d) If the Work includes a "NOTICE" text file as part of its
          distribution, then any Derivative Works that You distribute must
          include a readable copy of the attribution notices contained
          within such NOTICE file, excluding those notices that do not
          pertain to any part of the Derivative Works, in at least one
          of the following places: within a NOTICE text file distributed
          as part of the Derivative Works; within the Source form or
          documentation, if provided along with the Derivative Works; or,
          within a display generated by the Derivative Works, if and
          wherever such third-party notices normally appear. The contents
          of the NOTICE file are for informational purposes only and
          do not modify the License. You may add Your own attribution
          notices within Derivative Works that You distribute, alongside
          or as an addendum to the NOTICE text from the Work, provided
          that such additional attribution notices cannot be construed
          as modifying the License.

      You may add Your own copyright statement to Your modifications and
      may provide additional or different license terms and conditions
      for use, reproduction, or distribution of Your modifications, or
      for any such Derivative Works as a whole, provided Your use,
      reproduction, and distribution of the Work otherwise complies with
      the conditions stated in this License.

   5. Submission of Contributions. Unless You explicitly state otherwise,
      any Contribution intentionally submitted for inclusion in the Work
      by You to the Licensor shall be under the terms and conditions of
      this License, without any additional terms or conditions.
      Notwithstanding the above, nothing herein shall supersede or modify
      the terms of any separate license agreement you may have executed
      with Licensor regarding such Contributions.

   6. Trademarks. This License does not grant permission to use the trade
      names, trademarks, service marks, or product names of the Licensor,
      except as required for reasonable and customary use in describing the
      origin of the Work and reproducing the content of the NOTICE file.

   7. Disclaimer of Warranty. Unless required by applicable law or
      agreed to in writing, Licensor provides the Work (and each
      Contributor provides its Contributions) on an "AS IS" BASIS,
      WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
      implied, including, without limitation, any warranties or conditions
      of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
      PARTICULAR PURPOSE. You are solely responsible for determining the
      appropriateness of using or redistributing the Work and assume any
      risks associated with Your exercise of permissions under this License.

   8. Limitation of Liability. In no event and under no legal theory,
      whether in tort (including negligence), contract, or otherwise,
      unless required by applicable law (such as deliberate and grossly
      negligent acts) or agreed to in writing, shall any Contributor be
      liable to You for damages, including any direct, indirect, special,
      incidental, or consequential damages of any character arising as a
      result of this License or out of the use or inability to use the
      Work (including but not limited to damages for loss of goodwill,
      work stoppage, computer failure or malfunction, or any and all
      other commercial damages or losses), even if such Contributor
      has been advised of the possibility of such damages.

   9. Accepting Warranty or Additional Liability. While redistributing
      the Work or Derivative Works thereof, You may choose to offer,
      and charge a fee for, acceptance of support, warranty, indemnity,
      or other liability obligations and/or rights consistent with this
      License. However, in accepting such obligations, You may act only
      on Your own behalf and on Your sole responsibility, not on behalf
      of any other Contributor, and only if You agree to indemnify,
      defend, and hold each Contributor harmless for any liability
      incurred by, or claims asserted against, such Contributor by reason
      of your accepting any such warranty or additional liability.

   END OF TERMS AND CONDITIONS

   APPENDIX: How to apply the Apache License to your work.

      To apply the Apache License to your work, attach the following
      boilerplate notice, with the fields enclosed by brackets "[]"
      replaced with your own identifying information. (Don't include
      the brackets!)  The text should be enclosed in the appropriate
      comment syntax for the file format. We also recommend that a
      file or class name and description of purpose be included on the
      same "printed page" as the copyright notice for easier
      identification within third-party archives.

   Copyright [yyyy] [name of copyright owner]

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
```

### ONNX Runtime (MIT)

```text
MIT License

Copyright (c) Microsoft Corporation

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
