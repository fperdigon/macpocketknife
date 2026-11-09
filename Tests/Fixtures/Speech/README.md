<!--
Copyright 2026 Francisco Perdigon Romero and contributors

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
-->

# Speech fixtures

`dictation-en.m4a` and `dictation-es.m4a` are short synthetic clips used by
`scripts/run-speech-test.sh`. They were generated with Edge TTS voices
`en-US-AriaNeural` and `es-US-PalomaNeural` from these fixed sentences:

- English: "Remember to check the battery and the CPU usage after the build finishes, then paste the notes into the report."
- Spanish: "Recuerda revisar la batería y el uso del procesador cuando termine la compilación."

The clips are text-to-speech output and contain no personal data or real voices.

## Regenerating

```sh
python3 -m venv .venv && . .venv/bin/activate && pip install edge-tts
edge-tts --voice <voice> --text "<sentence>" --write-media x.mp3
afconvert -f m4af -d aac -b 32000 -c 1 x.mp3 dictation-<lang>.m4a
```

Use `en` with `en-US-AriaNeural` and `es` with `es-US-PalomaNeural`.

## Caveat

The licensing terms for reusing Edge TTS output have not been verified.

The separate [screen recording test](../../../CONTRIBUTING.md#screen-recording-tests) generates its own offline colour/tone clip to check video and system audio capture.
