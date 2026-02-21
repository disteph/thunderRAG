"""Shared helpers for corpus/test-case generators."""
import json

def E(id, mid, desc, rfc, proc=False):
    return {"id":id,"message_id":mid,"description":desc,"mark_processed":proc,"rfc822":rfc}

def P(frm,to,subj,mid,date,body,cc="",bcc="",irt="",ref=""):
    h=f"From: {frm}\r\nTo: {to}\r\n"
    if cc: h+=f"Cc: {cc}\r\n"
    if bcc: h+=f"Bcc: {bcc}\r\n"
    h+=f"Subject: {subj}\r\nMessage-Id: {mid}\r\nDate: {date}\r\n"
    if irt: h+=f"In-Reply-To: {irt}\r\nReferences: {ref}\r\n"
    h+="MIME-Version: 1.0\r\nContent-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\n"
    return h+body

def A(frm,to,subj,mid,date,body,fname,ct,cc="",irt="",ref=""):
    b=f"----=_Part_{mid[1:9]}"
    h=f"From: {frm}\r\nTo: {to}\r\n"
    if cc: h+=f"Cc: {cc}\r\n"
    h+=f"Subject: {subj}\r\nMessage-Id: {mid}\r\nDate: {date}\r\n"
    if irt: h+=f"In-Reply-To: {irt}\r\nReferences: {ref}\r\n"
    h+=f"MIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=\"{b}\"\r\n\r\n"
    h+=f"--{b}\r\nContent-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\n{body}\r\n\r\n"
    h+=f"--{b}\r\nContent-Type: {ct}\r\nContent-Disposition: attachment; filename=\"{fname}\"\r\nContent-Transfer-Encoding: base64\r\n\r\nUEsDBBQAAAAIAA==\r\n--{b}--"
    return h

def TC(id,cat,q,grp=None,dep=None,mc=[],mnc=[],cite=True,es=[],hk=[]):
    return {"id":id,"category":cat,"question":q,
            "session_group":grp or f"session_{id}","depends_on":dep,
            "criteria":{"must_contain_any":mc,"must_not_contain":mnc,
                        "must_cite_emails":cite,"expected_email_subjects_any":es,
                        "hallucination_keywords":hk}}

def write_json(path, data):
    with open(path,"w") as f: json.dump(data,f,indent=2)
    print(f"Wrote {path}")
