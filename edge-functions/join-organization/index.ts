import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import Transport from '../_shared/emailTransport.ts';
import corsHeaders from '../_shared/cors.ts';

type BodyType = {
    organization_id: number,
}

Deno.serve(async (req : Request) => {
    if (req.method === 'OPTIONS') {
        return new Response('ok', { headers: corsHeaders })
    }

    const {
        organization_id
    } : BodyType = await req.json();

    if (!organization_id) {
        return new Response("Missing field", { status: 400 })
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

    // this is the user that is stored in public.users
    const siteUser = verifiedUsers[0];

    /* check if organization exists */
    const { data: orgData, error: orgExistsError } = await supabaseClient.from('organizations')
        .select(`
            id,
            name,
            url
        `)
        .eq('id', organization_id);

    if (orgExistsError || !orgData || !orgData[0]) {
        return new Response("Organization does not exist.", { status: 404 }) // org not found 404
    }

    /* attempt to join organization (table constraint prevents duplicate members already) */
    type joinOrgType = {
        id: number,
        role: string,
        role_name?: string,
        active: boolean,
        users: {
            id: number,
            first_name: string,
            last_name: string,
            email: string,
            picture: string,
            is_faculty: boolean
        }
    }
    const { data: joinOrgData, error: joinOrgError } = await supabaseClient.from('memberships')
        .insert({
            organization_id,
            user_id: siteUser.id
         })
         .select(`
            id,
            role,
            role_name,
            active,
            users (
                id,
                first_name,
                last_name,
                email,
                picture,
                is_faculty
            )
        `)
        .returns<joinOrgType[]>();

    /* send error if failed to join organization */
    if (joinOrgError) {
        return new Response("Error joining organization", { status: 422 }) // unprocessable entity
    }

    /* if success, then send email to organization admins */
    type orgAdminType = {
        id: number,
        role: 'ADMIN' | 'CREATOR',
        users: {
            first_name: string,
            email: string
        }
    }
    const { data: orgAdmins, error: orgAdminError } = await supabaseClient.from('memberships')
        .select(`
            id,
            role,
            users!inner (
                first_name,
                email
            )
        `)
        .eq('organization_id', organization_id)
        .in('role', ['ADMIN', 'CREATOR'])
        .returns<orgAdminType[]>();
    
    if (orgAdminError || !orgAdmins || !orgAdmins.length) {
        return new Response("Failed to fetch organization admins.", { status: 500 })
    }

    for (const admin of orgAdmins) {
        const emailBody =
`Hi ${admin.users.first_name}!
        
You are receiving this message because you are an admin of ${orgData[0].name}
        
This email is to let you know that ${siteUser.first_name} ${siteUser.last_name} has requested to join ${orgData[0].name}. You can approve their request at ${Deno.env.get('SITE_URL')}/${orgData[0].url}/admin/member-requests`

        try {
            /* don't use await here. let this operation perform asynchronously */
            Transport.sendMail({
                from: Deno.env.get('NODEMAILER_FROM')!,
                to: admin.users.email,
                subject: `Someone has requested to join ${orgData[0].name} | Epsilon`,
                text: emailBody,
            })
        } catch (error) {
            console.log(error);
        }
    }

    return new Response(
        JSON.stringify({
            ...joinOrgData[0]
        }),
        {
            headers: { 'Content-Type': 'application/json' },
        }
    )
})
