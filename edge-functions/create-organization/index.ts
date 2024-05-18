import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import corsHeaders from '../_shared/cors.ts';

type BodyType = {
    name: string,
    url: string,
    socials: string,
    mission: string,
    purpose: string,
    benefit: string,
    keywords: string,
    tags: string[],
    appointment_procedures: string,
    uniqueness: string,
    meeting_schedule: string,
    meeting_days: string[],
    commitment_level: string,
    join_instructions: string,
    is_returning: boolean,
    returning_info: string
}

/* accepts JSON */
Deno.serve(async (req : Request) => {
    if (req.method === 'OPTIONS') {
        return new Response('ok', { headers: corsHeaders })
    }

    const authHeader = req.headers.get('Authorization')!
    const supabaseClient = createClient(
        Deno.env.get('SUPABASE_URL') ?? '',
        Deno.env.get('SUPABASE_ANON_KEY') ?? '',
        { global: { headers: { Authorization: authHeader } } }
    );

    const jwt = authHeader.split(" ")[1];
    const { data: userData } = await supabaseClient.auth.getUser(jwt);
    const user = userData.user;

    /* Failed to fetch supabase user */
    if (!user) {
        return new Response("Failed to fetch user.", { status: 500 });
    }

    /* check if user is a verified user. Verified user = the userdata that the site uses */
    const { data: verifiedUsers, error: verifiedUsersError } = await supabaseClient.from('users')
        .select('*')
        .eq('email', user.email);
    
    if (verifiedUsersError) {
        return new Response("Failed to fetch users associated email.", { status: 500 });
    }

    if (!verifiedUsers || !verifiedUsers.length) {
        return new Response("User is unauthorized.", { status: 401 });
    }

    const siteUser = verifiedUsers[0];
    const body : BodyType = await req.json();

    const { data: orgData, error: orgCreateError } = await supabaseClient.from('organizations')
        .insert({
            creator_id: siteUser.id,
            ...body
        })
        .select(`
            id
        `);
    
    if (orgCreateError || !orgData || !orgData.length) {
        return new Response("Error creating organization.", { status: 500 });
    }

    // success!
    return new Response(
        JSON.stringify({
            id: orgData[0].id,
        }),
        {
            headers: { 'Content-Type': 'application/json' },
        }
    );
})
