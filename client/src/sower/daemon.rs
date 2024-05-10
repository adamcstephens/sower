use super::Tree;

use std::time::Duration;

use phoenix_channels_client::url::Url;
use serde_json::json;

use phoenix_channels_client::{Event, EventPayload, EventsError, Payload, Socket, Topic, JSON};

impl Tree {
    pub async fn daemon(&mut self) -> Result<(), std::io::Error> {
        let url = Url::parse(&self.sower.clone().unwrap().channels_url).unwrap();
        let socket = Socket::spawn(url, None).unwrap();
        socket.connect(Duration::from_secs(10)).await.unwrap();

        let topic = Topic::from_string("tree:all".to_string());
        let channel = socket.channel(topic.clone(), None).await.unwrap();
        let events = channel.events();
        channel.join(Duration::from_secs(15)).await.unwrap();

        let Payload::JSONPayload { json } = channel
            .call(
                Event::from_string("register".to_string()),
                Payload::json_from_serialized(
                    json!({ "name": &self.name, "type": &self.seed_type}).to_string(),
                )
                .unwrap(),
                Duration::from_secs(5),
            )
            .await
            .unwrap()
        else {
            panic!("unable to register")
        };

        self.id = if let JSON::Str { string, .. } = &json {
            Some(string.to_string())
        } else {
            panic!("unable to parse registration response")
        };

        tokio::select! {
            _ = async {
                loop {
                    match events.event().await {
                        Ok(EventPayload { event, payload }) => match event {
                            Event::User {
                                user: user_event_name,
                            } => println!(
                                "channel {} event {} sent with payload {:#?}",
                                topic, user_event_name, payload
                            ),
                            Event::Phoenix { phoenix } => println!("channel {} {}", topic, phoenix),
                        },
                        Err(events_error) => match events_error {
                            EventsError::NoMoreEvents => break,
                            EventsError::MissedEvents { missed_event_count } => {
                                eprintln!("{} events missed on channel {}", missed_event_count, topic);
                            }
                        },
                    }
                }
            } => {}
        }

        // Leave the channel
        channel.leave().await.unwrap();

        // Disconnect the socket
        socket.disconnect().await.unwrap();

        Ok(())
    }
}
