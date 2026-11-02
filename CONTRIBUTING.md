# Contributing

Thanks for helping! The most wanted contributions are Uzum Bank and Paynet support,
and ready-made adapters for shelf and dart_frog.

1. Open an issue first for anything larger than a small fix.
2. Keep the package dependency-free and amounts in integer tiyin.
3. Every protocol rule needs a test. Run before pushing:

```sh
dart format --line-length 120 --set-exit-if-changed .
dart analyze --fatal-infos
dart test
```

Cite the official provider documentation or reference template for protocol behavior.
