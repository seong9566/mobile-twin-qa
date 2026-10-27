import Foundation
import Testing
@testable import QATwinCore

@Suite struct ProjectConfigTests {
    @Test func parsesServerSubkeysAndDefaults() throws {
        let yaml = """
        apps:
          android:
            package: com.example.app
            launch: com.example.app/.MainActivity
            permissions:
              - android.permission.ACCESS_FINE_LOCATION
              - android.permission.POST_NOTIFICATIONS
        environments:
          default: local
          local:
            health: http://{{mac_ip}}:5199/health
            start: server/run.sh --urls http://0.0.0.0:5199
            cwd: .
            start_timeout: 180
            vars: { API_BASE_URL: "http://{{mac_ip}}:5199" }
          dev: # 하위 키가 없는 서버
        build:
          android: cd app && flutter build apk --dart-define-from-file=$QA_APP_ENV
          android_apk: build/app/outputs/flutter-apk/app-debug.apk
          env_source: app/.env
        """

        let config = ProjectConfig.parse(yaml)
        let local = try #require(config.servers["local"])
        let dev = try #require(config.servers["dev"])

        #expect(local.health == "http://{{mac_ip}}:5199/health")
        #expect(local.start == "server/run.sh --urls http://0.0.0.0:5199")
        #expect(local.cwd == ".")
        #expect(local.startTimeout == 180)
        #expect(local.vars == ["API_BASE_URL": "http://{{mac_ip}}:5199"])
        #expect(dev.cwd == ".")
        #expect(dev.startTimeout == 60)
        #expect(config.defaultServer == "local")
        #expect(
            config.permissions
                == [
                    "android.permission.ACCESS_FINE_LOCATION",
                    "android.permission.POST_NOTIFICATIONS",
                ]
        )
        #expect(config.usesQAAppEnv)
        #expect(config.package == "com.example.app")
        #expect(config.launch == "com.example.app/.MainActivity")
        #expect(config.androidAPK == "build/app/outputs/flutter-apk/app-debug.apk")
        #expect(config.envSource == "app/.env")
    }

    @Test func parsesLegacyProjectYAML() throws {
        let fixture = try String(
            contentsOf: fixtureRoot().appending(path: "personal/demo_app/project.yaml"),
            encoding: .utf8
        )
        let yaml = fixture + """

        apps:
          android:
            package: com.example.demo
            launch: com.example.demo/.MainActivity

        build:
          android: flutter build apk --debug --dart-define-from-file=.env

        environments:
          default: dev
        """

        let config = ProjectConfig.parse(yaml)

        #expect(config.servers.keys.sorted() == ["dev"])
        #expect(config.servers["dev"]?.cwd == ".")
        #expect(config.servers["dev"]?.startTimeout == 60)
        #expect(config.usesQAAppEnv == false)
        #expect(config.envSource == ".env")
    }
}
