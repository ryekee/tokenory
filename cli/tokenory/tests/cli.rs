use assert_cmd::Command;
#[test]
fn report_is_json_and_invalid_dates_fail() {
    let t = tempfile::tempdir().unwrap();
    let result = Command::new(assert_cmd::cargo::cargo_bin!("tokenory"))
        .args(["--data-dir", t.path().to_str().unwrap(), "report"])
        .assert()
        .success();
    let json: serde_json::Value = serde_json::from_slice(&result.get_output().stdout).unwrap();
    assert_eq!(json["summary"]["tokens"], 0);
    Command::new(assert_cmd::cargo::cargo_bin!("tokenory"))
        .args([
            "--data-dir",
            t.path().to_str().unwrap(),
            "report",
            "--from",
            "2026-02-30",
        ])
        .assert()
        .failure();
}
