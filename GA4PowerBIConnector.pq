[Version = "0.7.2"]
section GA4PowerBIConnector;

//Authentication credentials

// you need to create this file 
appKey=Text.FromBinary(Extension.Contents("client_id"));
// you need to create this file 
appSecret=Text.FromBinary(Extension.Contents("client_secret"));
redirectUrl = "https://oauth.powerbi.com/views/oauthredirect.html";
token_uri = "https://accounts.google.com/o/oauth2/token";
authorize_uri = "https://accounts.google.com/o/oauth2/auth";
logout_uri = "https://accounts.google.com/logout";

windowWidth = 720;
windowHeight = 720;

//default number of rows of data to return per query 
gaRequestlimit = 100000;

scope_prefix = "https://www.googleapis.com/auth/";
scopes = {
"analytics.readonly"
};

Value.IfNull = (a, b) => if a <> null then a else b;
GetScopeString = (scopes as list, optional scopePrefix as text) as text =>
    let
        prefix = Value.IfNull(scopePrefix, ""),
        addPrefix = List.Transform(scopes, each prefix & _),
        asText = Text.Combine(addPrefix, " ")
    in
        asText;

[DataSource.Kind="GA4PowerBIConnector", Publish="GA4PowerBIConnector.Publish"]

//Navigation function setup
shared NavigationTable.Simple = () =>
    let
        objects = #table(
            {"Name", "Key", "Data", "ItemKind", "ItemName", "IsLeaf"},{
            {"GET Reports", "GA4PowerBIConnector.runReports", GA4PowerBIConnector.runReports, "Function", "Function", true}
            }),
        NavTable = Table.ToNavigationTable(objects, {"Key"}, "Name", "Data", "ItemKind", "ItemName", "IsLeaf")
    in
        NavTable;

//expose method and add a type function
shared GA4PowerBIConnector.runReports = Value.ReplaceType(runReports, runReportsType);

runReportsType = type function (
    StartDate as (type date meta [ 
        Documentation.FieldCaption = "Start Date"
    ]),
    EndDate as (type date meta [ 
        Documentation.FieldCaption = "End Date"
    ]),
     id as (type text meta [
        Documentation.FieldCaption = "GA4 property id",
        Documentation.FieldDescription = "property id can be found in in GA4 under property settings ",
        Documentation.SampleValues = {"123456789"}
    ]),
     dimensions as (type text meta [
        Documentation.FieldCaption = "Dimensions  (comma seperated)",
        Documentation.SampleValues = {"pageTitle,pageLocation"}
    ]),
     metrics as (type text meta [
        Documentation.FieldCaption = "Metrics (comma seperated)",
        Documentation.SampleValues = {"eventCount,eventCountPerUser"}
    ]),
      optional dimensionFilter as (type record meta [
        Documentation.FieldCaption = "dimension filter record",
        Documentation.SampleValues = {"see documentation for structure"}
    ]),
      optional metricFilter as (type record meta [
        Documentation.FieldCaption = "metric filter record",
        Documentation.SampleValues = {"see documentation for structure"}
    ]),
      optional orderBys as (type record meta [
        Documentation.FieldCaption = "orderBys record",
        Documentation.SampleValues = {"see documentation for structure"}
    ]),
      optional maxRows as (type number meta [
        Documentation.FieldCaption = "max rows to return",
        Documentation.SampleValues = {"0"}
    ])

    ) as table meta [
        Documentation.Name = "GA4 API Connector",
        Documentation.LongDescription = "By Gavin Brogan, for documentation and examples check the website https://cooriedug.com",
        Documentation.Examples = {[
            Description = "GA4 API connector by Gavin Brogan at the Coorie Dug  ",
            Code = "For documentation and examples check the website https://cooriedug.com"
        ]}
    ];


runReports = (
    StartDate as date, 
    EndDate as date,
    id as text,
    dimensions as text,
    metrics as text,
    optional dimensionFilter as record,
    optional metricFilter as record,
    optional orderBys as record, 
    optional maxRows as number ) =>
    let 
        // if the row limit is 0 or null then use the gaRequestLimit as default, if maxRows given then we will use that instead  
        limit = if (maxRows <> null) and (maxRows > 0) and (maxRows < gaRequestlimit) then maxRows else gaRequestlimit,
        // get the initial request 
        initial = runReportsPage(StartDate,EndDate,id, dimensions, metrics, 0, limit, dimensionFilter, metricFilter, orderBys),

        // Need to find out how many rows are in request in case paging is required 
        rowCount = initial[rowCount],
        // turn that data into a pretty table 
        parsed = runReportsParseResponse(initial),
        
        
        // THis bit deals with paging where required 
        // limit = gaRequestlimit = 100,000
        // if there is more data to get and I need it  
        maxRowsToFetch = if ((maxRows = null) or (maxRows = 0)) then rowCount else maxRows,
        out = if (rowCount > gaRequestlimit) and (maxRowsToFetch > gaRequestlimit) then 
            let
                //rowsToFetch is used to calculate how many loops we need to get all required data not just all the data
                //if max rows is null or 0 default to rowCount
                rowsToFetch = if (maxRowsToFetch < rowCount) then maxRowsToFetch else rowCount,
                //list of offsets to cummulate over starting a request limit in
                listToLoop = List.Numbers(gaRequestlimit,Number.RoundDown((rowsToFetch-1)/gaRequestlimit),gaRequestlimit),
                cummTable = List.Accumulate(listToLoop,parsed,(state,current) =>
                    //request next page, limit is full page or partial if maxRowsToFetch reached, if max rows is null or 0 use rowCount  
                    state & runReportsParseResponse(runReportsPage(StartDate,EndDate,id, dimensions, metrics, current, (if ((maxRowsToFetch - current) < gaRequestlimit ) then (maxRowsToFetch - current) else gaRequestlimit), dimensionFilter, metricFilter, orderBys))
                )   
            in 
                cummTable
        else
            parsed
    in
        out;

runReportsPage = (
    StartDate as date, 
    EndDate as date,
    id as text,
    dimensions as text,
    metrics as text,
    offset as number,
    limit as number,
    optional dimensionFilter as record,
    optional metricFilter as record,
    optional orderBys as record
    ) =>
    let 
        url = "https://analyticsdata.googleapis.com/v1beta/properties/" & Text.Clean(id) & ":runReport",
        // prepare the request params, oauth headers will be added automatically  
        params = [
                dateRanges = {[startDate = Date.ToText(StartDate, "yyyy-MM-dd"), endDate = Date.ToText(EndDate, "yyyy-MM-dd") ]},       
                dimensions = List.Transform(Text.Split(Text.Replace(dimensions, " ", ""), ","), each [ name = _] ),
                metrics = List.Transform(Text.Split(Text.Replace(metrics, " ", ""), ","), each [ name = _] ),
                dimensionFilter = if dimensionFilter <> [] then dimensionFilter else null,
                metricFilter = if metricFilter <> [] then metricFilter else null,
                orderBys = if orderBys <> [] then orderBys else null, 
                limit = limit, 
                offset = offset
            ],
        // if params are null get rid of them 
        cleanedParams = Record.RemoveFields(params, Table.SelectRows(Record.ToTable (params), each ([Value] = null))[Name]),  
        // JSONify the params for use
        postData = Json.FromValue(cleanedParams),
        // make request to API endpoint
        response = Web.Contents(url, [Content = postData]),
        // Parse response into an object we can use 
        jsonResponse = Json.Document(response),
        // pointless line of code
        GA = jsonResponse
    in 
        GA;

//parses the GA jsonResponse into a pretty table 
runReportsParseResponse = (GA) => 
    let 
        // get the dimension and metric headers and make one list that will be used to rename our table columns        
        headers = List.Transform(GA[dimensionHeaders], each _[name]) & List.Transform(GA[metricHeaders], each _[name]),
        // headerNames are camelCase so split them and capitalise each word (make proper)
        headersProper = List.Transform(headers, each 
                Text.Proper(Text.Combine(Splitter.SplitTextByCharacterTransition({"a".."z"},{"A".."Z"})(_)," "))
            ),

        #"rows table" = Table.FromList(GA[rows], Splitter.SplitByNothing(), null, null, ExtraValues.Error),
        #"expand rows" = Table.ExpandRecordColumn(#"rows table", "Column1", {"dimensionValues", "metricValues"}, {"dimensionValues", "metricValues"}),
        #"rows contents" = Table.AddColumn(#"expand rows", "Custom", each [dimensionValues] & [metricValues])[Custom],
        #"results table of records" = #table(headersProper, #"rows contents"),
        // find all the record columns uses utility function ColumnsOfAllRowType
        recordColumns = Table.ColumnsOfAllRowType(#"results table of records", type nullable record),
        // for each record column we need to split it using the utility function ExpandRecordColumnByKey
        output = Table.ExpandRecordColumnByKey(#"results table of records", recordColumns, "value")
        
    in
        output;

// utility function to find all columns of a type
Table.ColumnsOfAllRowType = (table as table, typ as type) as list => let
        ColumnNames = Table.ColumnNames(table ),
        ColumnsOfType = List.Select(ColumnNames, (name) => 
        List.AllTrue(List.Transform(Table.Column(table, name), (cell) => Type.Is(Value.Type(cell), typ))))
    in
        ColumnsOfType;
        
// utility function to expand all columns
Table.ExpandRecordColumnByKey = (table as table, columns as list, key as text) as table  => 
    List.Accumulate(columns, table, (state, columnToExpand) => 
    Table.ExpandRecordColumn(state, columnToExpand, {key}, { columnToExpand }));

// Data Source Kind description
GA4PowerBIConnector = [
    Authentication = [
        OAuth = [
            StartLogin = StartLogin,
            FinishLogin = FinishLogin
        ]
    ],
    Label = Extension.LoadString("GA4 Data API")];

// Data Source UI publishing description
GA4PowerBIConnector.Publish = [
    Beta = true,
    Category = "Other",
    ButtonText = { Extension.LoadString("ButtonTitle"), Extension.LoadString("ButtonHelp") },
    SourceImage = GA4PowerBIConnector.Icons,
    SourceTypeImage = GA4PowerBIConnector.Icons,
    LearnMoreUrl = "https://cooriedug.com"];

// Image assets for UI 
GA4PowerBIConnector.Icons = [
    Icon16 = { Extension.Contents("GA4PowerBIConnector16.png"), Extension.Contents("GA4PowerBIConnector20.png"), Extension.Contents("PQExtension124.png"), Extension.Contents("PQExtension132.png") },
    Icon32 = { Extension.Contents("GA4PowerBIConnector32.png"), Extension.Contents("GA4PowerBIConnector40.png"), Extension.Contents("PQExtension148.png"), Extension.Contents("PQExtension164.png") }];


// oAuth login start function 
StartLogin = (resourceUrl, state, display) =>
    let
        AuthorizeUrl = authorize_uri & "?" & Uri.BuildQueryString([
        client_id = appKey,  
        redirect_uri = redirectUrl,   
        state="security_token",
        scope = GetScopeString(scopes, scope_prefix),
        response_type = "code",
        response_mode = "query",
        access_type="offline",
        login = "login"    
    ])
    in
        [
            LoginUri = AuthorizeUrl,
            CallbackUri = redirectUrl,
            WindowHeight = 720,
            WindowWidth = 1024,
            Context = null
        ];

// oAuth login finish  function 
FinishLogin = (context, callbackUri, state) =>
    let
        parts = Uri.Parts(callbackUri)[Query],
        result = if (Record.HasFields(parts, {"error", "error_description"})) then 
                    error Error.Record(parts[error], parts[error_description], parts)
                 else
                   TokenMethod(parts[code])
    in
        result;
// handle oAuth token 
TokenMethod = (code) =>
    let
        response = Web.Contents(token_uri, [
            Content = Text.ToBinary(Uri.BuildQueryString([
                grant_type = "authorization_code",
                client_id = appKey,
                client_secret = appSecret,
                code = code,
                redirect_uri = redirectUrl])),
            Headers=[#"Content-type" = "application/x-www-form-urlencoded",#"Accept" = "application/json"], ManualStatusHandling = {400}]),
        body = Json.Document(response),
        result = if (Record.HasFields(body, {"error", "error_description"})) then 
                error Error.Record(body[error], body[error_description], body)
            else
                body
    in
        result;

// Create Navigation Table utility function
Table.ToNavigationTable = (
    table as table,
    keyColumns as list,
    nameColumn as text,
    dataColumn as text,
    itemKindColumn as text,
    itemNameColumn as text,
    isLeafColumn as text
) as table =>
    let
        tableType = Value.Type(table),
        newTableType = Type.AddTableKey(tableType, keyColumns, true) meta 
        [
            NavigationTable.NameColumn = nameColumn, 
            NavigationTable.DataColumn = dataColumn,
            NavigationTable.ItemKindColumn = itemKindColumn, 
            Preview.DelayColumn = itemNameColumn, 
            NavigationTable.IsLeafColumn = isLeafColumn
        ],
        navigationTable = Value.ReplaceType(table, newTableType)
    in
        navigationTable;