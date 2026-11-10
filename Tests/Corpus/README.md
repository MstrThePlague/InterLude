# Detection corpus

Labelled recordings the tests replay the speech rule over (`Tests/InterLudeCoreTests/CorpusTests.swift`), in CI on
Linux as well as on the Mac. Each recording is two files, named by the station's service ID:

- `<station>.csv`: the classifier's speech and music scores, as `classify` writes them. Numbers only: no audio and no
  words are kept, so nothing broadcast is in the repository.
- `<station>.labels.json`: each bulletin's start and end, as heard by ear.

To add one: record with `record`, score it with `classify`, label the bulletins by ear, copy both files here, run
`evaluate` on them, and add the figures it reports to `corpus` in `CorpusTests.swift`. When a change to the rule does
better, lower the figures in the same commit, so they can't slip back.
