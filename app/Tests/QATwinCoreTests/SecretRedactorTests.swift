import Testing
@testable import QATwinCore

@Test func redactsJSONEscapedValues() {
    let value = #"p"a\s/é"#
    let text = #"{"a":"p\"a\\s/é","b":"p\"a\\s\/é","c":"p\"a\\s/é","d":"p\\\"a\\\\s/é"}"#
    #expect(SecretRedactor.redact(text, values: [value]) == #"{"a":"****","b":"****","c":"****","d":"****"}"#)
}

@Test func skipsValuesShorterThanMinimum() {
    #expect(SecretRedactor.redact("ab abc", values: ["ab"]) == "ab abc")
}

@Test func masksFragmentsOnlyAtLastLineEdgesWhenAsked() {
    let text = "first ends with sec\ncretXYZ log line ends with secre"
    #expect(SecretRedactor.redact(text, values: ["secretXYZ"]) == text)
    #expect(
        SecretRedactor.redact(text, values: ["secretXYZ"], maskingEdgeFragments: true)
            == "first ends with sec\n**** log line ends with ****"
    )
}

@Test func masksWholeLastLineThatIsOnlyAFragment() {
    #expect(SecretRedactor.redact("a\nretXYZ", values: ["secretXYZ"], maskingEdgeFragments: true) == "a\n****")
}
