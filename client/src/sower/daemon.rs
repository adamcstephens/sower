use super::{Config, Tree};

use std::sync::Arc;
use std::time::Duration;

use phoenix_channels_client::url::Url;
use serde_json::json;
use tracing::info;

use phoenix_channels_client::{
    Channel, Event, EventPayload, EventsError, Payload, Socket, Topic, JSON,
};

pub struct Daemon {
    tree: Tree,
    socket: Arc<Socket>,
    lobby_channel: Arc<Channel>,
    lobby_topic: Arc<Topic>,
}

impl Daemon {
    pub async fn new(config: &Config) -> Self {
        let tree = Tree::new(config).await.expect("Failed to load tree");

        info!("Connecting to sower");
        let url = Url::parse(&tree.sower.clone().unwrap().channels_url).unwrap();
        let socket = Socket::spawn(url, None).unwrap();
        socket.connect(Duration::from_secs(10)).await.unwrap();

        info!("Joining lobby tree:all");
        let topic = Topic::from_string("tree:all".to_string());
        let channel = socket.channel(topic.clone(), None).await.unwrap();
        channel.join(Duration::from_secs(15)).await.unwrap();

        Self {
            lobby_channel: channel,
            lobby_topic: topic,
            socket,
            tree,
        }
    }

    pub async fn login(&mut self) {
        info!("Registering with sower");
        let Payload::JSONPayload { json } = self
            .lobby_channel
            .call(
                Event::from_string("register".to_string()),
                Payload::json_from_serialized(
                    json!({ "name": &self.tree.name, "type": &self.tree.seed_type}).to_string(),
                )
                .unwrap(),
                Duration::from_secs(5),
            )
            .await
            .unwrap()
        else {
            panic!("unable to register")
        };

        self.tree.id = if let JSON::Str { string, .. } = &json {
            info!("Received tree id {}", string);
            Some(string.to_string())
        } else {
            panic!("unable to parse registration response")
        };
    }

    pub async fn run(&mut self) -> Result<(), std::io::Error> {
        self.login().await;

        let events = self.lobby_channel.events();
        tokio::select! {
            _ = async {
                info!("Listening for events");
                loop {
                    match events.event().await {
                        Ok(EventPayload { event, payload }) => match event {
                            Event::User {
                                user: user_event_name,
                            } => println!(
                                "channel {} event {} sent with payload {:#?}",
                                self.lobby_topic, user_event_name, payload
                            ),
                            Event::Phoenix { phoenix } => println!("channel {} {}", self.lobby_topic, phoenix),
                        },
                        Err(events_error) => match events_error {
                            EventsError::NoMoreEvents => break,
                            EventsError::MissedEvents { missed_event_count } => {
                                eprintln!("{} events missed on channel {}", missed_event_count, self.lobby_topic);
                            }
                        },
                    }
                }
            } => {}
        }

        info!("Leaving the lobby");
        self.lobby_channel.leave().await.unwrap();

        info!("Closing socket");
        self.socket.disconnect().await.unwrap();

        info!("Shutdown");
        Ok(())
    }
}
