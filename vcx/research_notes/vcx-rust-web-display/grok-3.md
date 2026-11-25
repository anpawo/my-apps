AGREE
AGREE
AGREE (confirmed by the new measurement on WebKit 21624.5.1.11.3: shared configuration + data store still produced 8 separate WebContent processes at ~299 MB)
AGREE
AGREE (the measured 300 MB separate / 175 MB related on synthetic pages scales reasonably to the stated real-thread bands; today’s 253 MB for 7 windows is the correct baseline)
AGREE
AGREE
AGREE
AGREE
AGREE
AGREE (the measured 277–300 MB for 8 synthetic separate windows makes a 600 MB total stop threshold conservative and appropriate once real thread content is loaded)
AGREE (tauri-plugin-wdio-webdriver + WebdriverIO embedded provider exists on macOS; windowless WKWebView evaluateJavaScript is already proven in the new measurement, so Tauri is unnecessary)
AGREE