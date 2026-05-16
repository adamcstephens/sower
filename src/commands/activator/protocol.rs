use serde::{Deserialize, Serialize};

#[derive(Debug, Deserialize)]
pub struct Request {
    pub id: String,
    #[serde(rename = "type")]
    pub kind: String,
    #[serde(default)]
    pub path: String,
    #[serde(default)]
    pub mode: String,
    #[serde(default)]
    pub reason: String,
    #[serde(default)]
    pub seeds: Vec<SeedRef>,
}

#[derive(Debug, Deserialize)]
pub struct SeedRef {
    pub name: String,
    pub path: String,
}

#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum ResponseType {
    Output,
    Error,
    Complete,
}

#[derive(Debug, Serialize)]
pub struct Response {
    pub id: String,
    #[serde(rename = "type")]
    pub kind: ResponseType,
    #[serde(skip_serializing_if = "String::is_empty", default)]
    pub data: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub exit_code: Option<i32>,
}

impl Response {
    pub fn output(id: impl Into<String>, data: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            kind: ResponseType::Output,
            data: data.into(),
            exit_code: None,
        }
    }

    pub fn error(id: impl Into<String>, data: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            kind: ResponseType::Error,
            data: data.into(),
            exit_code: None,
        }
    }

    pub fn complete(id: impl Into<String>, exit_code: i32) -> Self {
        Self {
            id: id.into(),
            kind: ResponseType::Complete,
            data: String::new(),
            exit_code: Some(exit_code),
        }
    }
}
