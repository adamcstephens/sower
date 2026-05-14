use time::{OffsetDateTime, format_description::well_known::Rfc3339};

pub fn rfc3339_now() -> String {
    OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .unwrap_or_else(|_| String::new())
}
