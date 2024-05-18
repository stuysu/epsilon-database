import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import corsHeaders from '../_shared/cors.ts';
import Transport from '../_shared/emailTransport.ts';

type BodyType = {
    organization_id: number,
    title: string,
    description: string
}

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

    const bodyJson = await req.json();
    const body : BodyType = {
        organization_id: bodyJson.organization_id,
        title: bodyJson.title,
        description: bodyJson.description
    }

    /* create post */
    const { data: postData, error: postError } = await supabaseClient.from('posts')
        .insert(body)
        .select();
    
    if (postError || !postData || !postData.length) {
        return new Response("Error creating post.", { status: 500 });
    }

    /* asynchronously email all members of organization */
    type mtyp = {
        users: {
            first_name: string,
            email: string,
            is_faculty: boolean
        },
        organizations: { name: string }
    };
    supabaseClient.from("memberships")
        .select(`
            users!inner (
                first_name,
                email,
                is_faculty
            ),
            organizations!inner (
                name
            )
        `)
        .eq('organization_id', body.organization_id)
        .returns<mtyp[]>()
        .then(resp => {
            const { data: memberData, error: memberError } = resp;
            if (memberError || !memberData || !memberData.length) {
                console.log("Error fetching members.");
                return;
            }

            const recipientEmails = [];
            const orgName = memberData[0].organizations.name

            for (const member of memberData) {
                // do not notify faculty
                if (member.users.is_faculty && !bodyJson.notify_faculty) continue;

                recipientEmails.push(member.users.email);
            }

            const emailText = `${body.title}\n\n${body.description}`

            try {
                // don't use await here. let this operation perform asynchronously 
                Transport.sendMail({
                    from: Deno.env.get('NODEMAILER_FROM')!,
                    bcc: recipientEmails,
                    subject: `${body.title} | ${orgName}`,
                    text: emailText,
                })
            } catch (error) {
                console.log(error);
            }
        })

    return new Response(
        JSON.stringify({
            ...postData[0]
        }),
        {
            headers: { 'Content-Type': 'application/json' },
        }
    );
})
