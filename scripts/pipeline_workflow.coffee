# Description:
#   A module to assist in PipelineDeal's development workflow
#
# Dependencies:
#   None
#
# Configuration:
#   HUBOT_GITHUB_ACCESS_TOKEN - An access token for a Github user that will reassign PRs
#   HUBOT_GITHUB_QA_USERNAME - A Github username that PR's should be reassigned to
#   HUBOT_FOGBUGZ_HOST - The host URL of the Fogbugz resource
#   HUBOT_FOGBUGZ_TOKEN - A Fogbugz API token used to resolve open tickets
#
# Commands:
#   hubot pr accept <pr number> - Accepts a PR and reassigns to QA
#   hubot pr merge <pr number> - Merges a PR
#
# Author:
#   brandonhilkert
#

github_access_token = process.env.HUBOT_GITHUB_ACCESS_TOKEN
github_qa_username = process.env.HUBOT_GITHUB_QA_USERNAME

fogbugz_host = process.env.HUBOT_FOGBUGZ_HOST
fogbugz_token = process.env.HUBOT_FOGBUGZ_TOKEN

jira_token = process.env.JIRA_TOKEN

JiraPeerReviewed = 751
JiraClosed = 781
JiraBusinessOwnerApproved = 771
JiraPRCustomField = "customfield_10400"
JiraReleaseVersionCustomField = "customfield_10401"

ReleaseVersion = null

module.exports = (robot) ->

  robot.respond /pr dev accept (\d+)/i, (msg) ->
    prNum = msg.match[1]
    devAcceptPR(prNum, msg)

  robot.respond /pr qa accept (\d+)/i, (msg) ->
    prNum = msg.match[1]
    qAAcceptPR(prNum, msg)

  robot.respond /pr deadbeats/i, (msg) ->
    parseIssues = (issues) ->
      parsedIssues = []
      now = new Date()
      millisecondsPerDay = 1000 * 60 * 60 * 24;
      for issue in issues
        diff = now - (new Date(issue.created_at))
        daysOld = diff / millisecondsPerDay

        oldIssue = {}
        oldIssue.number = issue.number
        oldIssue.title = issue.title
        if issue.assignee
          oldIssue.owner = issue.assignee.login
        else
          oldIssue.owner = "UNASSIGNED"
        oldIssue.href = issue.html_url
        oldIssue.daysOld = Math.round(daysOld)
        if daysOld >= 1 and oldIssue.title.indexOf("WIP") == -1
          parsedIssues.push(oldIssue)
      parsedIssues

    github_issue_api_url = "https://api.github.com/repos/PipelineDeals/pipeline_deals/issues?access_token=#{github_access_token}"
    msg.http(github_issue_api_url).get() (err, res, body) ->
      issues = JSON.parse(body)
      issues = parseIssues(issues)
      for issue in issues
        msg.send "PR #{issue.number} is #{issue.daysOld} days old, owned by #{issue.owner} -- #{issue.href}"
      if issues.length > 5
        msg.send "That's a lot of issues, and a lot of deadbeats.  Get your act together, fools!"
      else
        msg.send "Nice work managing those PRs!!"

  robot.respond /set release version (.*)/i, (msg) ->
    version = msg.match[1]
    ReleaseVersion = version
    msg.send "Ok, deploy version is #{ReleaseVersion}"

  robot.respond /get release version/i, (msg) ->
    msg.send "The release version currently is #{ReleaseVersion}"

  robot.respond /pr merge (\d+)/i, (msg) ->
    prNum = msg.match[1]

    # close the jira ticket and set the release version
    work = (ticketNum) ->
      setJiraTicketReleaseVersion(ticketNum, msg)
      transitionTicket(ticketNum, JiraClosed, msg)
    getJiraTicketFromPR(prNum, msg, work)

    # put deploy version in PR and merge it
    commentOnPR(prNum, "Deploy version: #{ReleaseVersion}", msg)
    mergePR(prNum, msg)


  robot.respond /business owner approve (.*)/i, (msg) ->
    ticket = msg.match[1]
    transitionTicket(ticket, JiraBusinessOwnerApproved, msg)
    work = (prNum) -> commentOnPR(prNum, approveComment("#{msg.message.user.name} (Business Owner)"), msg)
    getPrFromJiraTicket(ticket, msg, work)

  ######################################
  # Utility functions
  ######################################

  devAcceptPR = (prNum, msg) ->
    commentOnPR(prNum, approveComment(msg.message.user.name), msg)
    assignPRtoQA(prNum, msg)
    msg.send("The ticket has been accepted by the Devs... yup.")

  qAAcceptPR = (prNum, msg) ->
    commentOnPR(prNum, approveComment("#{msg.message.user.name} (QA)"), msg)
    markTicketAsPeerReviewed(prNum, msg)
    msg.send("The ticket has been accepted by QA.")

  commentOnPR = (prNum, comment, msg) ->
    github_comment_api_url = "https://api.github.com/repos/PipelineDeals/pipeline_deals/issues/#{prNum}/comments?access_token=#{github_access_token}"
    payload = JSON.stringify({ body: comment})
    robot.http(github_comment_api_url).post(payload)

  approveComment = (user) -> "#{user} approves!  :#{getEmoji()}:"

  assignPRtoQA = (prNum, msg) ->
    github_issue_api_url = "https://api.github.com/repos/PipelineDeals/pipeline_deals/issues/#{prNum}?access_token=#{github_access_token}"
    payload = JSON.stringify({ assignee: github_qa_username })
    msg.http(github_issue_api_url).post(payload) (err, res, body) ->
      response = JSON.parse body

  getJiraTicketFromPR = (prNum, msg, cb) ->
    github_issue_api_url = "https://api.github.com/repos/PipelineDeals/pipeline_deals/issues/#{prNum}?access_token=#{github_access_token}"
    msg.http(github_issue_api_url).get(github_issue_api_url) (err, res, body) ->
      json = JSON.parse body
      title = json['title']
      re = /\[.*?\]/
      ticketNum = re.exec(title)[0].replace('#','').replace('[','').replace(']','')
      cb(ticketNum)

  getPrFromJiraTicket= (ticket, msg, cb) ->
    msg.
      http("https://pipelinedeals.atlassian.net/rest/api/2/issue/#{ticket}").
      headers("Authorization": "Basic #{jira_token}", "Content-Type": "application/json").
      get() (err, res, body) ->
        json = JSON.parse(body)
        url = json.fields[JiraPRCustomField]
        if url
          cb(url.split('/').reverse()[0])
        else
          cb(null)

  markTicketAsPeerReviewed = (prNum, msg) ->
    github_issue_api_url = "https://api.github.com/repos/PipelineDeals/pipeline_deals/issues/#{prNum}?access_token=#{github_access_token}"
    work = (ticketNum) ->
      transitionTicket(ticketNum, JiraPeerReviewed, msg)
      addPrURLToTicket(ticketNum, prNum, msg)
    getJiraTicketFromPR(prNum, msg, work)

  addPrURLToTicket = (ticketNum, prNum, msg) ->
    githubUrl = "https://github.com/PipelineDeals/pipeline_deals/pull/#{prNum}"
    payload = JSON.stringify({ fields: {JiraPRCustomField: githubUrl }})
    msg.
      http("https://pipelinedeals.atlassian.net/rest/api/2/issue/#{ticketNum}").
      headers("Authorization": "Basic #{jira_token}", "Content-Type": "application/json").
      put(payload) (err, res, body) ->
        console.log "err = ", err

  transitionTicket = (ticketNum, jiraTransitionId, msg) ->
    payload = JSON.stringify({transition:{id: jiraTransitionId}})
    msg.
      http("https://pipelinedeals.atlassian.net/rest/api/2/issue/#{ticketNum}/transitions").
      headers("Authorization": "Basic #{jira_token}", "Content-Type": "application/json").
      post(payload) (err, res, body) ->
        msg.send "Ticket #{ticketNum} has been updated."
        console.log "err = ", err

  mergePR = (prNum, msg) ->
    github_issue_api_url = "https://api.github.com/repos/PipelineDeals/pipeline_deals/pulls/#{prNum}/merge?access_token=#{github_access_token}"
    msg.http(github_issue_api_url).put(JSON.stringify({commit_message: "Merge into master"})) (err, res, body) -> console.log err

  setJiraTicketReleaseVersion = (ticketNum, msg) ->
    fields = {}
    fields[JiraReleaseVersionCustomField] = ReleaseVersion
    payload = {"fields": fields}
    msg.
      http("https://pipelinedeals.atlassian.net/rest/api/2/issue/#{ticketNum}").
      headers("Authorization": "Basic #{jira_token}", "Content-Type": "application/json").
      put(JSON.stringify(payload)) (err, res, body) ->
        console.log "err = ", err

  getEmoji = ->
    emojis = ["+1", "smile", "relieved", "sparkles", "star2", "heart", "notes", "ok_hand", "clap", "raised_hands", "dancer", "kiss", "100", "ship", "shipit", "beer", "high_heel", "moneybag", "zap", "sunny", "dolphin"]
    emojis[Math.floor(Math.random() * emojis.length)]
