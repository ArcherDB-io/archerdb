use archerdb::{GeoEvent, GeoEventOptions, RadiusQuery};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    futures::executor::block_on(main_async())
}

async fn main_async() -> Result<(), Box<dyn std::error::Error>> {
    let address = std::env::var("ARCHERDB_ADDRESS")
        .ok()
        .unwrap_or_else(|| "127.0.0.1:3001".to_string());
    let client = archerdb::Client::new(0, &address)?;

    let base_lat = 37.7749;
    let base_lon = -122.4194;

    let mut events: Vec<GeoEvent> = Vec::new();
    for i in 0..25 {
        let event = GeoEvent::from_options(GeoEventOptions {
            entity_id: archerdb::id(),
            latitude: base_lat + (i as f64) * 0.0005,
            longitude: base_lon + (i as f64) * 0.0005,
            group_id: 42,
            ..Default::default()
        })?;
        events.push(event);
    }

    let errors = client.insert_events(&events).await?;
    if !errors.is_empty() {
        eprintln!("insert errors: {}", errors.len());
    }

    let query = RadiusQuery::new(base_lat, base_lon, 1500.0, 5)?.with_group(42);
    let results = client.query_radius(&query).await?;

    println!("Page 1: {} events within 1.5km", results.events.len());
    println!("Has more: {}", results.has_more);

    if results.has_more && results.cursor > 0 {
        let next_query = RadiusQuery::new(base_lat, base_lon, 1500.0, 5)?
            .with_group(42)
            .with_time_range(0, results.cursor.saturating_sub(1));
        let page2 = client.query_radius(&next_query).await?;
        println!("Page 2: {} events within 1.5km", page2.events.len());
    }

    Ok(())
}
