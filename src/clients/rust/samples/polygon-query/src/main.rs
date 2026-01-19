use archerdb::{GeoEvent, GeoEventOptions, PolygonQuery, PolygonVertex};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    futures::executor::block_on(main_async())
}

async fn main_async() -> Result<(), Box<dyn std::error::Error>> {
    let address = std::env::var("ARCHERDB_ADDRESS")
        .ok()
        .unwrap_or_else(|| "127.0.0.1:3001".to_string());
    let client = archerdb::Client::new(0, &address)?;

    let locations = [
        ("Inside A", 37.7890, -122.4020),
        ("Inside B", 37.7900, -122.3980),
        ("Outside A", 37.8030, -122.4310),
    ];

    let mut events: Vec<GeoEvent> = Vec::new();
    for (name, lat, lon) in locations {
        let event = GeoEvent::from_options(GeoEventOptions {
            entity_id: archerdb::id(),
            latitude: lat,
            longitude: lon,
            group_id: 7,
            ..Default::default()
        })?;
        println!("Inserted {} at ({:.4}, {:.4})", name, lat, lon);
        events.push(event);
    }

    let errors = client.insert_events(&events).await?;
    if !errors.is_empty() {
        eprintln!("insert errors: {}", errors.len());
    }

    let vertices = vec![
        PolygonVertex::from_degrees(37.7920, -122.4050),
        PolygonVertex::from_degrees(37.7920, -122.3950),
        PolygonVertex::from_degrees(37.7860, -122.3950),
        PolygonVertex::from_degrees(37.7860, -122.4050),
    ];
    let query = PolygonQuery::new(vertices, 100)?;
    let results = client.query_polygon(&query).await?;

    println!("Found {} events inside polygon", results.events.len());

    Ok(())
}
