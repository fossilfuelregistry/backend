import parse from 'csv-parse/lib/sync.js'
import { pgClient } from "./pool.js"
import copyStream from 'pg-copy-streams'
import { initCountries, initUnitConversionGraph } from "./unitConverter.js"
import ProgressBar from 'progress'
import _fs from 'fs'
import EventEmitter from 'events'

const fs = _fs.promises
const copyFrom = copyStream.from
const args = process.argv.slice( 2 )

const pointColumns = [ "project_id", "data_type", "year", "volume", "unit", "grade", "fossil_fuel_type", "subtype", "source_id", "quality", "data_year" ]

try {
	if( !args[ 0 ] ) {
		console.log( 'Missing project file!' )
		process.exit()
	}

	if( !args[ 1 ] ) {
		console.log( 'Missing data point file!' )
		process.exit()
	}

	await pgClient.connect()
	console.log( 'DB connected.' )

	await initUnitConversionGraph( pgClient )
	await initCountries( pgClient )

	const content = await fs.readFile( args[ 0 ] )
	const data = await fs.readFile( args[ 1 ] )
	const _projects = parse( content, { columns: true, skip_empty_lines: true } )
	const dataPoints = parse( data, { columns: true, skip_empty_lines: true } )

	if( _projects?.length === 0 ) {
		console.log( `Zarro projects.` )
		process.exit()
	}

	if( args[ 2 ] ) {
		const deleted = await pgClient.query( `DELETE FROM public.project WHERE ${args[2]}`, [] )
		console.log( `Deleted ${ deleted.rowCount } projects.` )
	}

	// First look for multiple entries and merge company data
	let lastProj = {}
	const projects = []
	_projects.forEach( p => {
		if( lastProj.id !== p.id ) {
			if( lastProj.id ) {
				projects.push( lastProj )
				//console.log( lastProj )
			}
			lastProj = p
		} else {
			lastProj.operator_name += '\f' + p.operator_name
		}
	} )
	projects.push( lastProj )

	const bar = new ProgressBar( '[:bar] :percent', { total: projects.length, width: 100 } )
	let noDataCounter = 0

	console.log( `Importing ${ projects?.length } projects.` )

	for( const project of projects ) {
		const params = [
			/* 01 */ project[ 'iso3166' ],
			/* 02 */ project[ 'iso3166_2' ] ?? '',
			/* 03 */ project[ 'project_identifier' ],
			/* 04 */ project[ 'operator_name' ],
			/* 05 */ project[ 'oc_operator_id' ]
		]

		if( !project.id ) {
			console.log( project )
			throw new Error( 'Project has no id property.' )
		}

		const inserted = await pgClient.query(
			`INSERT INTO public.project	
             (iso3166, iso3166_2, project_identifier, operator_name, oc_operator_id, project_type)
             VALUES ($1, $2, $3, $4, $5, 'dense')
             RETURNING *`, params )

		const last_id = inserted.rows?.[ 0 ]?.id

		const points = dataPoints.filter( p => p.project_id === project[ 'id' ] )
		if( points.length === 0 ) {
			noDataCounter++
			// console.log( project )
			// console.log( dataPoints[ 0 ] )
			// process.exit()
		} else {
			const insertStream = pgClient.query( copyFrom( `COPY public.project_data_point ( ${ pointColumns.join( ',' ) } ) FROM STDIN CSV` ) )

			for( let point of points ) {
				point.project_id = last_id
				const pointLine = pointColumns.map( c => point[ c ] ).join( ',' )
				//console.log( pointLine )
				insertStream.write( pointLine + '\n' )
			}
			insertStream.end()
			await EventEmitter.once( insertStream, 'finish' )
		}
		bar.tick()
	}

	await pgClient.end()
	if( noDataCounter > 0 ) console.log( noDataCounter + ' projects had no data points!' )
	console.log( 'DB disconnected.' )
} catch( e ) {
	console.log( e )
}
