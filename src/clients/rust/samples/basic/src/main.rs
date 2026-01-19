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
    for i in 0..5 {
        let event = GeoEvent::from_options(GeoEventOptions {
            entity_id: archerdb::id(),
            latitude: base_lat + (i as f64) * 0.001,
            longitude: base_lon + (i as f64) * 0.001,
            group_id: 1,
            ..Default::default()
        })?;
        events.push(event);
    }

    let errors = client.insert_events(&events).await?;
    for error in errors {
        eprintln!("Event {} failed: {:?}", error.index, error.result);
    }

    let query = RadiusQuery::new(base_lat, base_lon, 1000.0, 100)?;
    let results = client.query_radius(&query).await?;
    println!("Found {} events within 1km", results.events.len());

    if let Some(first) = events.first() {
        let found = client.get_latest_by_uuid(first.entity_id).await?;
        if let Some(event) = found {
            println!(
                "Latest for {}: ({:.4}, {:.4})",
                event.entity_id,
                event.latitude(),
                event.longitude()
            );
        }
    }

    println!("ok");
    Ok(())
}
