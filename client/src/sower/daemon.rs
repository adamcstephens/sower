use super::Tree;

use std::time::Duration;

use phoenix_channels_client::url::Url;
use serde_json::json;

use phoenix_channels_client::{Event, EventPayload, EventsError, Payload, Socket, Topic};

impl Tree {
    pub async fn daemon(&self) -> Result<(), std::io::Error> {
        dbg!(&self.sower.channels_url);

        // URL with params for authentication
        let url = Url::parse(&self.sower.channels_url).unwrap();

        // Create a socket
        let socket = Socket::spawn(url, None).unwrap();

        // Connect the socket
        socket.connect(Duration::from_secs(10)).await.unwrap();

        // Create a channel with no params
        let topic = Topic::from_string("tree:all".to_string());
        let channel = socket.channel(topic.clone(), None).await.unwrap();
        //let some_event_channel = channel.clone();

        // Events are received as a broadcast with the name of the event and payload associated with the event
        let events = channel.events();
        tokio::spawn(async move {
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
        });
        // Join the channel with a 15 second timeout
        channel.join(Duration::from_secs(15)).await.unwrap();

        // Send a message, waiting for a reply until timeout
        let reply_payload = channel
            .call(
                Event::from_string("reply_ok_tuple".to_string()),
                Payload::json_from_serialized(json!({ "name": "foo", "message": "hi"}).to_string())
                    .unwrap(),
                Duration::from_secs(5),
            )
            .await
            .unwrap();

        dbg!(reply_payload);

        // Send a message, not waiting for a reply
        channel
            .cast(
                Event::from_string("noreply".to_string()),
                Payload::json_from_serialized(
                    json!({ "name": "foo", "message": "jeez"}).to_string(),
                )
                .unwrap(),
            )
            .await
            .unwrap();

        // Leave the channel
        channel.leave().await.unwrap();

        // Disconnect the socket
        socket.disconnect().await.unwrap();

        Ok(())
    }
}
