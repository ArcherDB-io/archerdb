// section:imports
use archerdb::{GeoEvent, GeoEventOptions, RadiusQuery};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    futures::executor::block_on(main_async())
}

async fn main_async() -> Result<(), Box<dyn std::error::Error>> {
    let address = std::env::var("ARCHERDB_ADDRESS")
        .ok()
        .unwrap_or_else(|| "127.0.0.1:3001".to_string());
    let client = archerdb::Client::new(0, &address)?;

    let entity_id = archerdb::id();
    let base_lat = 37.7749;
    let base_lon = -122.4194;

    let initial = GeoEvent::from_options(GeoEventOptions {
        entity_id,
        latitude: base_lat,
        longitude: base_lon,
        group_id: 1,
        ..Default::default()
    })?;

    let errors = client.insert_events(&[initial]).await?;
    for error in errors {
        eprintln!("Insert error at {}: {:?}", error.index, error.result);
    }

    if let Some(event) = client.get_latest_by_uuid(entity_id).await? {
        println!("Inserted entity at ({:.4}, {:.4})", event.latitude(), event.longitude());
    }

    let updates = vec![
        GeoEvent::from_options(GeoEventOptions {
            entity_id,
            latitude: base_lat + 0.001,
            longitude: base_lon + 0.001,
            group_id: 1,
            ..Default::default()
        })?,
        GeoEvent::from_options(GeoEventOptions {
            entity_id,
            latitude: base_lat + 0.002,
            longitude: base_lon + 0.002,
            group_id: 1,
            ..Default::default()
        })?,
    ];

    let errors = client.upsert_events(&updates).await?;
    for error in errors {
        eprintln!("Upsert error at {}: {:?}", error.index, error.result);
    }

    let query = RadiusQuery::new(base_lat, base_lon, 2000.0, 100)?;
    let results = client.query_radius(&query).await?;
    println!("Found {} events in radius", results.events.len());

    let delete_result = client.delete_entities(&[entity_id]).await?;
    println!(
        "Deleted {} entities, {} not found",
        delete_result.deleted_count,
        delete_result.not_found_count
    );

    let remaining = client.get_latest_by_uuid(entity_id).await?;
    if remaining.is_none() {
        println!("Entity deleted successfully");
    }

    Ok(())
}
// endsection:imports
