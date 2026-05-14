use std::sync::{Arc, Mutex};
use tracing::field::{Field, Visit};
use tracing::{Event, Subscriber};
use tracing_subscriber::layer::{Context, Layer};
use tracing_subscriber::registry::LookupSpan;

use super::activate::OutputCallback;
use super::time::rfc3339_now;

#[derive(Clone, Default)]
pub struct CallbackSlot(Arc<Mutex<Option<OutputCallback>>>);

impl CallbackSlot {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn set(&self, cb: OutputCallback) {
        *self.0.lock().unwrap() = Some(cb);
    }

    pub fn clear(&self) {
        *self.0.lock().unwrap() = None;
    }

    fn get(&self) -> Option<OutputCallback> {
        self.0.lock().unwrap().clone()
    }
}

pub struct CallbackLayer {
    slot: CallbackSlot,
}

impl CallbackLayer {
    pub fn new(slot: CallbackSlot) -> Self {
        Self { slot }
    }
}

impl<S: Subscriber + for<'a> LookupSpan<'a>> Layer<S> for CallbackLayer {
    fn on_event(&self, event: &Event<'_>, _ctx: Context<'_, S>) {
        let Some(cb) = self.slot.get() else {
            return;
        };

        let mut visitor = MessageVisitor::default();
        event.record(&mut visitor);

        let is_error = *event.metadata().level() == tracing::Level::ERROR;
        let line = format!(
            "{} [activator] {}{}",
            rfc3339_now(),
            visitor.message,
            visitor.fields
        );
        cb(&line, is_error);
    }
}

#[derive(Default)]
struct MessageVisitor {
    message: String,
    fields: String,
}

impl Visit for MessageVisitor {
    fn record_str(&mut self, field: &Field, value: &str) {
        if field.name() == "message" {
            self.message = value.to_string();
        } else {
            self.fields.push(' ');
            self.fields.push_str(field.name());
            self.fields.push('=');
            self.fields.push_str(value);
        }
    }

    fn record_debug(&mut self, field: &Field, value: &dyn std::fmt::Debug) {
        if field.name() == "message" {
            self.message = format!("{value:?}");
        } else {
            use std::fmt::Write;
            let _ = write!(self.fields, " {}={value:?}", field.name());
        }
    }
}
