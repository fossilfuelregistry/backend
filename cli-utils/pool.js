import pg from 'pg'
import dotenv from "dotenv"

const { Client } = pg

dotenv.config()

let ssl = false

if( process.env.POSTGRES_ADMIN_URL?.indexOf( 'localhost' ) < 0 )
	ssl = { rejectUnauthorized: false }

const pgClient = new Client( {
	connectionString: process.env.POSTGRES_ADMIN_URL,
	application_name: 'CLI-UTIL',
	ssl
} )

export { pgClient }
