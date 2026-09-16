#!/bin/zsh
# тесты: unit не требуют GPU и экрана, all запускаются только на MacBook и на время закрывают экран анимацией
set -euo pipefail

usage='Использование: scripts/test.sh unit|all'
(( $# == 1 )) || { print -u2 -- $usage; exit 2 }
root=${0:A:h:h}
case $1 in
  unit)
    selection=(-only-testing:KampsisTests/MotionTests -only-testing:KampsisTests/DecisionTests
               -only-testing:KampsisTests/HardwareTests -only-testing:KampsisTests/ReleaseTests)
    ;;
  all)
    selection=()
    print 'Полный прогон: нужен MacBook с активным встроенным экраном, окна тестов появятся поверх рабочего стола.'
    ;;
  *) print -u2 -- $usage; exit 2 ;;
esac
command -v xcodegen >/dev/null || { print -u2 'нужен XcodeGen: brew install xcodegen'; exit 2 }

cd $root
xcodegen generate --quiet
derived=${KAMPSIS_DERIVED_DATA:-$(mktemp -d ${TMPDIR:-/tmp}/KampsisTests.XXXXXX)}
results=${KAMPSIS_TEST_RESULTS:-$derived/Tests.xcresult}
xcodebuild -project Kampsis.xcodeproj -scheme Kampsis -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath $derived -resultBundlePath $results \
  -testLanguage en CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES $selection test
